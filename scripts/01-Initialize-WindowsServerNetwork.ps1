param(
    [string]$TargetName,
    [string]$TimeZone,
    [string]$IPv4,
    [Nullable[int]]$PrefixLength,
    [string]$Gateway,
    [string[]]$DnsServers,
    [switch]$RestartIfNeeded
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

function Read-RequiredInt {
    param(
        [string]$Prompt,
        [int]$DefaultValue
    )

    while ($true) {
        $value = Read-RequiredValue -Prompt $Prompt -DefaultValue $DefaultValue
        $parsed = 0
        if ([int]::TryParse($value, [ref]$parsed)) {
            return $parsed
        }
    }
}

function Read-DnsServerList {
    param(
        [string[]]$DefaultServers
    )

    while ($true) {
        $defaultValue = $DefaultServers -join ','
        $value = Read-RequiredValue -Prompt 'DNS servers (comma-separated)' -DefaultValue $defaultValue
        $servers = @(
            $value.Split(',') |
            ForEach-Object { $_.Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        )

        if ($servers.Count -gt 0) {
            return $servers
        }
    }
}

function Resolve-DeploymentInputs {
    $script:TargetName = if ([string]::IsNullOrWhiteSpace($TargetName)) {
        Read-RequiredValue -Prompt 'Target hostname' -DefaultValue 'DC01'
    } else {
        $TargetName.Trim()
    }

    $script:TimeZone = if ([string]::IsNullOrWhiteSpace($TimeZone)) {
        Read-RequiredValue -Prompt 'Windows time zone ID' -DefaultValue 'UTC'
    } else {
        $TimeZone.Trim()
    }

    $script:IPv4 = if ([string]::IsNullOrWhiteSpace($IPv4)) {
        Read-RequiredValue -Prompt 'IPv4 address' -DefaultValue '10.20.20.11'
    } else {
        $IPv4.Trim()
    }

    $script:PrefixLength = if ($null -eq $PrefixLength) {
        Read-RequiredInt -Prompt 'IPv4 prefix length' -DefaultValue 24
    } else {
        [int]$PrefixLength
    }

    $script:Gateway = if ([string]::IsNullOrWhiteSpace($Gateway)) {
        Read-RequiredValue -Prompt 'Default gateway' -DefaultValue '10.20.20.1'
    } else {
        $Gateway.Trim()
    }

    $script:DnsServers = if ($DnsServers.Count -eq 0) {
        Read-DnsServerList -DefaultServers @('127.0.0.1', '1.1.1.1')
    } else {
        @(
            $DnsServers |
            ForEach-Object { $_.Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        )
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

function Set-ExactDnsServers {
    param(
        [int]$InterfaceIndex,
        [string[]]$DesiredServers
    )

    $current = (Get-DnsClientServerAddress -InterfaceIndex $InterfaceIndex -AddressFamily IPv4).ServerAddresses
    if (@($current) -join ',' -ne @($DesiredServers) -join ',') {
        Set-DnsClientServerAddress -InterfaceIndex $InterfaceIndex -ServerAddresses $DesiredServers
    }
}

function Set-ExactIPv4Configuration {
    param(
        [int]$InterfaceIndex,
        [string]$DesiredIPv4,
        [int]$DesiredPrefixLength,
        [string]$DesiredGateway
    )

    $existing = Get-NetIPAddress -InterfaceIndex $InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue

    foreach ($address in $existing) {
        if ($address.IPAddress -eq $DesiredIPv4 -and $address.PrefixLength -eq $DesiredPrefixLength) {
            continue
        }

        if ($address.IPAddress -like '169.254.*') {
            continue
        }

        Remove-NetIPAddress `
            -InterfaceIndex $InterfaceIndex `
            -AddressFamily IPv4 `
            -IPAddress $address.IPAddress `
            -Confirm:$false `
            -ErrorAction SilentlyContinue
    }

    $desiredAddress = Get-NetIPAddress `
        -InterfaceIndex $InterfaceIndex `
        -AddressFamily IPv4 `
        -ErrorAction SilentlyContinue |
        Where-Object {
            $_.IPAddress -eq $DesiredIPv4 -and
            $_.PrefixLength -eq $DesiredPrefixLength
        } |
        Select-Object -First 1

    if (-not $desiredAddress) {
        New-NetIPAddress `
            -InterfaceIndex $InterfaceIndex `
            -IPAddress $DesiredIPv4 `
            -PrefixLength $DesiredPrefixLength
    }

    $defaultRoutes = Get-NetRoute `
        -InterfaceIndex $InterfaceIndex `
        -DestinationPrefix '0.0.0.0/0' `
        -AddressFamily IPv4 `
        -ErrorAction SilentlyContinue

    foreach ($route in $defaultRoutes) {
        if ($route.NextHop -ne $DesiredGateway) {
            Remove-NetRoute `
                -InterfaceIndex $InterfaceIndex `
                -DestinationPrefix '0.0.0.0/0' `
                -NextHop $route.NextHop `
                -Confirm:$false `
                -ErrorAction SilentlyContinue
        }
    }

    $desiredRoute = Get-NetRoute `
        -InterfaceIndex $InterfaceIndex `
        -DestinationPrefix '0.0.0.0/0' `
        -AddressFamily IPv4 `
        -ErrorAction SilentlyContinue |
        Where-Object NextHop -eq $DesiredGateway |
        Select-Object -First 1

    if (-not $desiredRoute) {
        New-NetRoute `
            -InterfaceIndex $InterfaceIndex `
            -DestinationPrefix '0.0.0.0/0' `
            -NextHop $DesiredGateway `
            -RouteMetric 256 | Out-Null
    }
}

function Install-RequiredFeatures {
    $requiredFeatures = 'AD-Domain-Services', 'DNS', 'DHCP'
    $missingFeatures = Get-WindowsFeature $requiredFeatures |
        Where-Object InstallState -ne 'Installed' |
        Select-Object -ExpandProperty Name

    if ($missingFeatures) {
        Install-WindowsFeature -Name $missingFeatures -IncludeManagementTools | Out-Null
    }
}

Resolve-DeploymentInputs

$adapter = Get-PrimaryAdapter
$restartRequired = $false

if ((Get-TimeZone).Id -ne $TimeZone) {
    Set-TimeZone -Id $TimeZone
}

Set-ExactIPv4Configuration `
    -InterfaceIndex $adapter.ifIndex `
    -DesiredIPv4 $IPv4 `
    -DesiredPrefixLength $PrefixLength `
    -DesiredGateway $Gateway

Set-ExactDnsServers `
    -InterfaceIndex $adapter.ifIndex `
    -DesiredServers $DnsServers

if ($env:COMPUTERNAME -ne $TargetName) {
    Rename-Computer -NewName $TargetName -Force
    $restartRequired = $true
}

Install-RequiredFeatures

$summary = [pscustomobject]@{
    Hostname = $env:COMPUTERNAME
    TargetName = $TargetName
    Adapter = $adapter.Name
    IPv4 = $IPv4
    PrefixLength = $PrefixLength
    Gateway = $Gateway
    DnsServers = ($DnsServers -join ', ')
    RestartRequired = $restartRequired
}

$summary | Format-List | Out-String | Write-Output

if ($restartRequired -and $RestartIfNeeded) {
    Write-Output 'Restarting to complete hostname change.'
    Restart-Computer -Force
}
