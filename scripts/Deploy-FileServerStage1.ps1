param(
    [string]$TargetName,
    [string]$IPv4,
    [Nullable[int]]$PrefixLength,
    [string]$Gateway,
    [string[]]$DnsServers,
    [string]$DomainName,
    [string]$OuPath,
    [string]$JoinCredentialUser,
    [switch]$RestartIfNeeded
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Assert-Elevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)

    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run this script from an elevated PowerShell session.'
    }
}

function Read-RequiredValue {
    param([string]$Prompt,[string]$DefaultValue)
    $fullPrompt = $Prompt
    if ($DefaultValue) { $fullPrompt = "$Prompt [$DefaultValue]" }
    while ($true) {
        $value = Read-Host -Prompt $fullPrompt
        if (-not [string]::IsNullOrWhiteSpace($value)) { return $value.Trim() }
        if (-not [string]::IsNullOrWhiteSpace($DefaultValue)) { return $DefaultValue }
    }
}

function Read-RequiredInt {
    param([string]$Prompt,[int]$DefaultValue)
    while ($true) {
        $value = Read-RequiredValue -Prompt $Prompt -DefaultValue $DefaultValue
        $parsed = 0
        if ([int]::TryParse($value, [ref]$parsed)) { return $parsed }
    }
}

function Read-DnsServerList {
    param([string[]]$DefaultServers)
    while ($true) {
        $value = Read-RequiredValue -Prompt 'DNS servers (comma-separated)' -DefaultValue ($DefaultServers -join ',')
        $servers = @($value.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        if ($servers.Count -gt 0) { return $servers }
    }
}

function Resolve-Inputs {
    $script:TargetName = if ([string]::IsNullOrWhiteSpace($TargetName)) { Read-RequiredValue 'Target hostname' 'FS01' } else { $TargetName.Trim() }
    $script:IPv4 = if ([string]::IsNullOrWhiteSpace($IPv4)) { Read-RequiredValue 'IPv4 address' '10.20.20.21' } else { $IPv4.Trim() }
    $script:PrefixLength = if ($null -eq $PrefixLength) { Read-RequiredInt 'IPv4 prefix length' 24 } else { [int]$PrefixLength }
    $script:Gateway = if ([string]::IsNullOrWhiteSpace($Gateway)) { Read-RequiredValue 'Default gateway' '10.20.20.1' } else { $Gateway.Trim() }
    $script:DnsServers = if ($DnsServers.Count -eq 0) { Read-DnsServerList -DefaultServers @('10.20.20.11') } else { @($DnsServers | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
    $script:DomainName = if ([string]::IsNullOrWhiteSpace($DomainName)) { Read-RequiredValue 'Domain FQDN' 'example.corp' } else { $DomainName.Trim() }
    $script:OuPath = if ([string]::IsNullOrWhiteSpace($OuPath)) { Read-RequiredValue 'Target server OU DN' 'OU=Servers,OU=Example,DC=example,DC=corp' } else { $OuPath.Trim() }
    $script:JoinCredentialUser = if ([string]::IsNullOrWhiteSpace($JoinCredentialUser)) { Read-RequiredValue 'Domain join user' 'example.corp\\svc.domainjoin' } else { $JoinCredentialUser.Trim() }
}

function Get-PrimaryAdapter {
    $adapter = Get-NetAdapter | Where-Object Status -eq 'Up' | Sort-Object ifIndex | Select-Object -First 1
    if (-not $adapter) { throw 'No active network adapter was found.' }
    return $adapter
}

function Test-DomainReadiness {
    param([int]$InterfaceIndex)

    $dnsServers = (Get-DnsClientServerAddress -InterfaceIndex $InterfaceIndex -AddressFamily IPv4).ServerAddresses
    if (-not $dnsServers -or $dnsServers.Count -eq 0) {
        throw 'No IPv4 DNS servers are configured on the active adapter.'
    }

    try {
        Resolve-DnsName $script:DomainName -ErrorAction Stop | Out-Null
    }
    catch {
        throw "DNS validation failed for domain '$($script:DomainName)'."
    }
}

function Set-ExactDnsServers {
    param([int]$InterfaceIndex,[string[]]$DesiredServers)
    $current = (Get-DnsClientServerAddress -InterfaceIndex $InterfaceIndex -AddressFamily IPv4).ServerAddresses
    if (@($current) -join ',' -ne @($DesiredServers) -join ',') {
        Set-DnsClientServerAddress -InterfaceIndex $InterfaceIndex -ServerAddresses $DesiredServers
    }
}

function Set-ExactIPv4Configuration {
    param([int]$InterfaceIndex,[string]$DesiredIPv4,[int]$DesiredPrefixLength,[string]$DesiredGateway)
    $existing = Get-NetIPAddress -InterfaceIndex $InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
    foreach ($address in $existing) {
        if ($address.IPAddress -eq $DesiredIPv4 -and $address.PrefixLength -eq $DesiredPrefixLength) { continue }
        if ($address.IPAddress -like '169.254.*') { continue }
        Remove-NetIPAddress -InterfaceIndex $InterfaceIndex -AddressFamily IPv4 -IPAddress $address.IPAddress -Confirm:$false -ErrorAction SilentlyContinue
    }
    $desiredAddress = Get-NetIPAddress -InterfaceIndex $InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -eq $DesiredIPv4 -and $_.PrefixLength -eq $DesiredPrefixLength } | Select-Object -First 1
    if (-not $desiredAddress) {
        New-NetIPAddress -InterfaceIndex $InterfaceIndex -IPAddress $DesiredIPv4 -PrefixLength $DesiredPrefixLength | Out-Null
    }
    $defaultRoutes = Get-NetRoute -InterfaceIndex $InterfaceIndex -DestinationPrefix '0.0.0.0/0' -AddressFamily IPv4 -ErrorAction SilentlyContinue
    foreach ($route in $defaultRoutes) {
        if ($route.NextHop -ne $DesiredGateway) {
            Remove-NetRoute -InterfaceIndex $InterfaceIndex -DestinationPrefix '0.0.0.0/0' -NextHop $route.NextHop -Confirm:$false -ErrorAction SilentlyContinue
        }
    }
    $desiredRoute = Get-NetRoute -InterfaceIndex $InterfaceIndex -DestinationPrefix '0.0.0.0/0' -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object NextHop -eq $DesiredGateway | Select-Object -First 1
    if (-not $desiredRoute) {
        New-NetRoute -InterfaceIndex $InterfaceIndex -DestinationPrefix '0.0.0.0/0' -NextHop $DesiredGateway -RouteMetric 256 | Out-Null
    }
}

Resolve-Inputs
Assert-Elevated

$adapter = Get-PrimaryAdapter
Set-ExactIPv4Configuration -InterfaceIndex $adapter.ifIndex -DesiredIPv4 $script:IPv4 -DesiredPrefixLength $script:PrefixLength -DesiredGateway $script:Gateway
Set-ExactDnsServers -InterfaceIndex $adapter.ifIndex -DesiredServers $script:DnsServers
Set-DnsClient -InterfaceIndex $adapter.ifIndex -ConnectionSpecificSuffix $script:DomainName -RegisterThisConnectionsAddress $true -UseSuffixWhenRegistering $true
Test-DomainReadiness -InterfaceIndex $adapter.ifIndex

$computerSystem = Get-CimInstance Win32_ComputerSystem
$renameRequired = $env:COMPUTERNAME -ne $script:TargetName
$joinRequired = -not $computerSystem.PartOfDomain
$restartRequired = $false

if ($renameRequired -or $joinRequired) {
    $credential = Get-Credential -UserName $script:JoinCredentialUser -Message 'Enter domain join credential for FS01'
    if ($renameRequired) {
        Add-Computer -DomainName $script:DomainName -Credential $credential -OUPath $script:OuPath -NewName $script:TargetName -Force
        $restartRequired = $true
        Write-Output 'The server was renamed and joined to the domain.'
    } else {
        Add-Computer -DomainName $script:DomainName -Credential $credential -OUPath $script:OuPath -Force
        $restartRequired = $true
        Write-Output 'The server was joined to the domain.'
    }
} else {
    Write-Output 'No rename or domain join action is required.'
}

Write-Output "TargetName: $($script:TargetName)"
Write-Output "IPv4: $($script:IPv4)/$($script:PrefixLength)"
Write-Output "Gateway: $($script:Gateway)"
Write-Output "DnsServers: $($script:DnsServers -join ', ')"
Write-Output "DomainValidation: OK"

if ($restartRequired -and $RestartIfNeeded) {
    Restart-Computer -Force
} elseif ($restartRequired) {
    Write-Output 'A restart is required to complete FS01 stage 1.'
}
