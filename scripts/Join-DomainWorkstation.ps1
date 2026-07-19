param(
    [string]$TargetName,
    [string]$DomainName,
    [string]$OuPath,
    [string]$DomainControllerFqdn,
    [string]$ExpectedDnsServer,
    [string]$ExpectedGateway,
    [string]$LegacyBuildGateway = '10.20.110.1',
    [string]$InternetTestHost,
    [pscredential]$DomainCredential,
    [switch]$RemoveLegacyBuildGateway,
    [switch]$RestartIfNeeded,
    [switch]$SkipInternetTest
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Read-RequiredValue {
    param(
        [string]$Prompt,
        [string]$DefaultValue
    )

    $fullPrompt = $Prompt
    if ($DefaultValue) {
        $fullPrompt = "$Prompt [$DefaultValue]"
    }

    while ($true) {
        $value = Read-Host -Prompt $fullPrompt
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return $value.Trim()
        }

        if (-not [string]::IsNullOrWhiteSpace($DefaultValue)) {
            return $DefaultValue
        }
    }
}

function Resolve-Inputs {
    $script:TargetName = if ([string]::IsNullOrWhiteSpace($TargetName)) {
        Read-RequiredValue -Prompt 'Target workstation name' -DefaultValue $env:COMPUTERNAME
    }
    else {
        $TargetName.Trim()
    }

    $script:DomainName = if ([string]::IsNullOrWhiteSpace($DomainName)) {
        Read-RequiredValue -Prompt 'Domain FQDN' -DefaultValue 'example.corp'
    }
    else {
        $DomainName.Trim()
    }

    $script:OuPath = if ([string]::IsNullOrWhiteSpace($OuPath)) {
        Read-RequiredValue -Prompt 'Target OU distinguished name' -DefaultValue 'OU=Workstations,OU=Example,DC=example,DC=corp'
    }
    else {
        $OuPath.Trim()
    }

    $script:DomainControllerFqdn = if ([string]::IsNullOrWhiteSpace($DomainControllerFqdn)) {
        Read-RequiredValue -Prompt 'Domain controller FQDN for validation' -DefaultValue 'dc01.example.corp'
    }
    else {
        $DomainControllerFqdn.Trim()
    }

    $script:ExpectedDnsServer = if ([string]::IsNullOrWhiteSpace($ExpectedDnsServer)) {
        Read-RequiredValue -Prompt 'Expected DNS server IPv4' -DefaultValue '10.20.20.11'
    }
    else {
        $ExpectedDnsServer.Trim()
    }

    $script:ExpectedGateway = if ([string]::IsNullOrWhiteSpace($ExpectedGateway)) {
        Read-RequiredValue -Prompt 'Expected default gateway IPv4' -DefaultValue '10.20.30.1'
    }
    else {
        $ExpectedGateway.Trim()
    }

    $script:InternetTestHost = if ([string]::IsNullOrWhiteSpace($InternetTestHost)) {
        Read-RequiredValue -Prompt 'Internet validation host' -DefaultValue 'github.com'
    }
    else {
        $InternetTestHost.Trim()
    }
}

function Assert-Elevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)

    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run this script from an elevated PowerShell session.'
    }
}

function Get-PrimaryAdapter {
    $adapter = Get-NetAdapter |
        Where-Object Status -eq 'Up' |
        Sort-Object ifIndex |
        Select-Object -First 1

    if (-not $adapter) {
        throw 'No active network adapter was found.'
    }

    return $adapter
}

function Test-FirstBootState {
    $setupState = Get-ItemProperty 'HKLM:\SYSTEM\Setup'
    $imageState = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State'

    if ($setupState.OOBEInProgress -ne 0) {
        throw 'OOBE is still in progress. Stop and fix the source template before domain join.'
    }

    if ($setupState.SystemSetupInProgress -ne 0) {
        throw 'System setup is still in progress. Stop and fix the source template before domain join.'
    }

    if ($imageState.ImageState -ne 'IMAGE_STATE_COMPLETE') {
        throw "Unexpected image state '$($imageState.ImageState)'. Stop and fix the source template before domain join."
    }
}

function Test-NetworkReadiness {
    param(
        [Microsoft.Management.Infrastructure.CimInstance]$Adapter
    )

    $ipConfig = Get-NetIPConfiguration -InterfaceIndex $Adapter.ifIndex
    $ipv4Address = $ipConfig.IPv4Address | Select-Object -First 1
    $defaultGateways = @($ipConfig.IPv4DefaultGateway)
    $dnsServers = (Get-DnsClientServerAddress -InterfaceIndex $Adapter.ifIndex -AddressFamily IPv4).ServerAddresses

    if (-not $ipv4Address) {
        throw 'No IPv4 address is assigned on the active adapter.'
    }

    if (-not $ipv4Address.PrefixOrigin -or $ipv4Address.PrefixOrigin -ne 'Dhcp') {
        throw 'The active adapter is not using DHCP for IPv4. Workstation onboarding requires DHCP.'
    }

    if ($defaultGateways.Count -eq 0) {
        throw 'No default gateway is present on the active adapter.'
    }

    $gatewayAddresses = @($defaultGateways | ForEach-Object NextHop | Where-Object { $_ })
    if ($ExpectedGateway -notin $gatewayAddresses) {
        throw "Expected gateway $ExpectedGateway was not found on the active adapter."
    }
    $unexpectedGateways = @($gatewayAddresses | Where-Object { $_ -ne $ExpectedGateway })
    if ($unexpectedGateways.Count -gt 0) {
        throw "Unexpected default gateway(s) detected: $($unexpectedGateways -join ', '). Correct the template or use the explicit legacy-build cleanup switch."
    }

    if (-not $dnsServers -or $dnsServers.Count -eq 0) {
        throw 'No IPv4 DNS servers are configured on the active adapter.'
    }

    if ($ExpectedDnsServer -notin $dnsServers) {
        throw "Expected DNS server $ExpectedDnsServer was not found on the active adapter."
    }

    Resolve-DnsName $DomainControllerFqdn | Out-Null

    if (-not $SkipInternetTest) {
        $internetTest = Test-NetConnection $InternetTestHost -Port 443 -WarningAction SilentlyContinue
        if (-not $internetTest.TcpTestSucceeded) {
            throw "Internet validation failed for $InternetTestHost on TCP 443."
        }
    }

    Write-Output "ActiveAdapter: $($Adapter.Name)"
    Write-Output "IPv4: $($ipv4Address.IPAddress)"
    Write-Output "Gateway: $($gatewayAddresses -join ', ')"
    Write-Output "DnsServers: $($dnsServers -join ', ')"
}

function Get-DomainJoinCredential {
    if ($DomainCredential) { return $DomainCredential }

    $defaultUser = "Administrator@$($script:DomainName)"

    try {
        return Get-Credential -UserName $defaultUser -Message 'Enter domain join credential'
    }
    catch {
        throw 'A valid domain credential is required to join the workstation.'
    }
}

function Remove-LegacyBuildRoute {
    param([Microsoft.Management.Infrastructure.CimInstance]$Adapter)

    if (-not $RemoveLegacyBuildGateway) { return }
    if ([string]::IsNullOrWhiteSpace($LegacyBuildGateway)) {
        throw 'LegacyBuildGateway is required when RemoveLegacyBuildGateway is used.'
    }

    $interface = Get-NetIPInterface -InterfaceIndex $Adapter.ifIndex -AddressFamily IPv4
    if ($interface.Dhcp -ne 'Enabled') {
        throw 'Legacy build-route cleanup is allowed only on a DHCP-enabled adapter.'
    }

    $legacyRoutes = @(Get-NetRoute `
        -PolicyStore PersistentStore `
        -InterfaceIndex $Adapter.ifIndex `
        -DestinationPrefix '0.0.0.0/0' `
        -ErrorAction SilentlyContinue |
        Where-Object NextHop -eq $LegacyBuildGateway)

    foreach ($route in $legacyRoutes) {
        Remove-NetRoute `
            -PolicyStore PersistentStore `
            -InterfaceIndex $Adapter.ifIndex `
            -DestinationPrefix $route.DestinationPrefix `
            -NextHop $route.NextHop `
            -Confirm:$false
    }

    $activeLegacyRoutes = @(Get-NetRoute `
        -PolicyStore ActiveStore `
        -InterfaceIndex $Adapter.ifIndex `
        -DestinationPrefix '0.0.0.0/0' `
        -ErrorAction SilentlyContinue |
        Where-Object NextHop -eq $LegacyBuildGateway)

    foreach ($route in $activeLegacyRoutes) {
        Remove-NetRoute `
            -PolicyStore ActiveStore `
            -InterfaceIndex $Adapter.ifIndex `
            -DestinationPrefix $route.DestinationPrefix `
            -NextHop $route.NextHop `
            -Confirm:$false
    }

    Write-Output "LegacyBuildPersistentRoutesRemoved: $($legacyRoutes.Count)"
    Write-Output "LegacyBuildActiveRoutesRemoved: $($activeLegacyRoutes.Count)"
}

Resolve-Inputs
Assert-Elevated
Test-FirstBootState

$adapter = Get-PrimaryAdapter
Remove-LegacyBuildRoute -Adapter $adapter
Test-NetworkReadiness -Adapter $adapter

$computerSystem = Get-CimInstance Win32_ComputerSystem
$renameRequired = $computerSystem.Name -ne $TargetName
$joinRequired = -not $computerSystem.PartOfDomain
$restartRequired = $false

Write-Output "CurrentComputerName: $($computerSystem.Name)"
Write-Output "TargetComputerName: $TargetName"
Write-Output "PartOfDomain: $($computerSystem.PartOfDomain)"

if (-not $renameRequired -and -not $joinRequired) {
    Write-Output 'No rename or domain join action is required.'
    return
}

$credential = Get-DomainJoinCredential

if ($renameRequired -and $joinRequired) {
    Add-Computer `
        -DomainName $DomainName `
        -Credential $credential `
        -OUPath $OuPath `
        -NewName $TargetName `
        -Force

    $restartRequired = $true
    Write-Output 'The workstation was renamed and joined to the domain.'
}
elseif ($joinRequired) {
    Add-Computer `
        -DomainName $DomainName `
        -Credential $credential `
        -OUPath $OuPath `
        -Force

    $restartRequired = $true
    Write-Output 'The workstation was joined to the domain.'
}
elseif ($renameRequired) {
    Rename-Computer -NewName $TargetName -DomainCredential $credential -Force
    $restartRequired = $true
    Write-Output 'The workstation was renamed.'
}

if ($restartRequired -and $RestartIfNeeded) {
    Restart-Computer -Force
}
elseif ($restartRequired) {
    Write-Output 'A restart is required to complete the workstation onboarding.'
}
