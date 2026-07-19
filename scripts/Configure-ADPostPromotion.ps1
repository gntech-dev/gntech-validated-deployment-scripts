param(
    [string]$DomainFqdn,
    [string]$DomainDn,
    [string]$DcFqdn,
    [string]$DcIp,
    [string]$UpnSuffix,
    [string[]]$DnsForwarders,
    [string]$ServerReverseNetworkId,
    [string]$WorkstationReverseNetworkId,
    [string]$DhcpScopeName,
    [string]$DhcpScopeId,
    [string]$DhcpStartRange,
    [string]$DhcpEndRange,
    [string]$DhcpSubnetMask,
    [string]$DhcpRouter,
    [string]$EnterpriseRootOuName,
    [string]$OuTemplateCsvPath,
    [switch]$ValidateOnly
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

function Read-StringList {
    param(
        [string]$Prompt,
        [string[]]$DefaultValues
    )

    while ($true) {
        $defaultValue = $DefaultValues -join ','
        $value = Read-RequiredValue -Prompt $Prompt -DefaultValue $defaultValue
        $items = @(
            $value.Split(',') |
            ForEach-Object { $_.Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        )

        if ($items.Count -gt 0) {
            return $items
        }
    }
}

function Resolve-Inputs {
    $script:DomainFqdn = if ([string]::IsNullOrWhiteSpace($DomainFqdn)) {
        Read-RequiredValue -Prompt 'Domain FQDN' -DefaultValue 'example.corp'
    } else { $DomainFqdn.Trim() }

    $script:DomainDn = if ([string]::IsNullOrWhiteSpace($DomainDn)) {
        Read-RequiredValue -Prompt 'Domain distinguished name' -DefaultValue 'DC=example,DC=corp'
    } else { $DomainDn.Trim() }

    $script:DcFqdn = if ([string]::IsNullOrWhiteSpace($DcFqdn)) {
        Read-RequiredValue -Prompt 'Domain controller FQDN' -DefaultValue 'DC01.example.corp'
    } else { $DcFqdn.Trim() }

    $script:DcIp = if ([string]::IsNullOrWhiteSpace($DcIp)) {
        Read-RequiredValue -Prompt 'Domain controller IPv4' -DefaultValue '10.20.20.11'
    } else { $DcIp.Trim() }

    $script:UpnSuffix = if ([string]::IsNullOrWhiteSpace($UpnSuffix)) {
        Read-RequiredValue -Prompt 'User UPN suffix' -DefaultValue 'example.corp'
    } else { $UpnSuffix.Trim() }

    $script:DnsForwarders = if ($DnsForwarders.Count -eq 0) {
        Read-StringList -Prompt 'DNS forwarders (comma-separated)' -DefaultValues @('1.1.1.1','9.9.9.9')
    } else {
        @($DnsForwarders | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }

    $script:ServerReverseNetworkId = if ([string]::IsNullOrWhiteSpace($ServerReverseNetworkId)) {
        Read-RequiredValue -Prompt 'Server reverse zone network' -DefaultValue '10.20.20.0/24'
    } else { $ServerReverseNetworkId.Trim() }

    $script:WorkstationReverseNetworkId = if ([string]::IsNullOrWhiteSpace($WorkstationReverseNetworkId)) {
        Read-RequiredValue -Prompt 'Workstation reverse zone network' -DefaultValue '10.20.30.0/24'
    } else { $WorkstationReverseNetworkId.Trim() }

    $script:DhcpScopeName = if ([string]::IsNullOrWhiteSpace($DhcpScopeName)) {
        Read-RequiredValue -Prompt 'DHCP scope name' -DefaultValue 'VLAN30 Workstations'
    } else { $DhcpScopeName.Trim() }

    $script:DhcpScopeId = if ([string]::IsNullOrWhiteSpace($DhcpScopeId)) {
        Read-RequiredValue -Prompt 'DHCP scope ID' -DefaultValue '10.20.30.0'
    } else { $DhcpScopeId.Trim() }

    $script:DhcpStartRange = if ([string]::IsNullOrWhiteSpace($DhcpStartRange)) {
        Read-RequiredValue -Prompt 'DHCP start range' -DefaultValue '10.20.30.100'
    } else { $DhcpStartRange.Trim() }

    $script:DhcpEndRange = if ([string]::IsNullOrWhiteSpace($DhcpEndRange)) {
        Read-RequiredValue -Prompt 'DHCP end range' -DefaultValue '10.20.30.199'
    } else { $DhcpEndRange.Trim() }

    $script:DhcpSubnetMask = if ([string]::IsNullOrWhiteSpace($DhcpSubnetMask)) {
        Read-RequiredValue -Prompt 'DHCP subnet mask' -DefaultValue '255.255.255.0'
    } else { $DhcpSubnetMask.Trim() }

    $script:DhcpRouter = if ([string]::IsNullOrWhiteSpace($DhcpRouter)) {
        Read-RequiredValue -Prompt 'DHCP router option' -DefaultValue '10.20.30.1'
    } else { $DhcpRouter.Trim() }

    $script:EnterpriseRootOuName = if ([string]::IsNullOrWhiteSpace($EnterpriseRootOuName)) {
        Read-RequiredValue -Prompt 'Enterprise root OU name' -DefaultValue 'EXAMPLE'
    } else { $EnterpriseRootOuName.Trim() }

    $script:OuTemplateCsvPath = if ([string]::IsNullOrWhiteSpace($OuTemplateCsvPath)) {
        $scriptDirectory = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
            $PSScriptRoot
        } else {
            (Get-Location).Path
        }

        $defaultCsv = Join-Path -Path $scriptDirectory -ChildPath 'ou-baseline.csv'
        if (Test-Path -LiteralPath $defaultCsv) { $defaultCsv } else { '' }
    } else { $OuTemplateCsvPath.Trim() }
}

function Ensure-Module {
    param([string]$Name)
    Import-Module $Name
}

function Ensure-UpnSuffix {
    $partitionsDn = "CN=Partitions,CN=Configuration,$script:DomainDn"
    $partitionsObject = Get-ADObject $partitionsDn -Properties uPNSuffixes
    if ($partitionsObject.uPNSuffixes -notcontains $script:UpnSuffix) {
        Set-ADObject $partitionsDn -Add @{ uPNSuffixes = $script:UpnSuffix }
    }
}

function Ensure-DnsForwarders {
    $existingForwarders = @(Get-DnsServerForwarder -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.IPAddress -is [array]) {
            $_.IPAddress | ForEach-Object { $_.IPAddressToString }
        }
        elseif ($_.IPAddress) {
            $_.IPAddress.IPAddressToString
        }
    })

    foreach ($forwarder in $script:DnsForwarders) {
        if ($existingForwarders -notcontains $forwarder) {
            Add-DnsServerForwarder -IPAddress $forwarder
        }
    }
}

function Ensure-DnsZone {
    param([string]$NetworkId)
    $networkAddress = $NetworkId.Split('/')[0]
    $octets = $networkAddress.Split('.')
    $zoneName = "$($octets[2]).$($octets[1]).$($octets[0]).in-addr.arpa"

    if (-not (Get-DnsServerZone -Name $zoneName -ErrorAction SilentlyContinue)) {
        Add-DnsServerPrimaryZone -NetworkId $NetworkId -ReplicationScope Forest
    }
}

function Ensure-DhcpAuthorization {
    $authorized = @(Get-DhcpServerInDC -ErrorAction SilentlyContinue)
    if (-not ($authorized | Where-Object DnsName -eq $script:DcFqdn)) {
        Add-DhcpServerInDC -DnsName $script:DcFqdn -IpAddress $script:DcIp
    }

    & netsh dhcp add securitygroups | Out-Null
    Restart-Service DHCPServer -Force
    Start-Sleep -Seconds 10
}

function Ensure-DhcpScope {
    if (-not (Get-DhcpServerv4Scope -ErrorAction SilentlyContinue | Where-Object ScopeId -eq $script:DhcpScopeId)) {
        Add-DhcpServerv4Scope `
            -Name $script:DhcpScopeName `
            -StartRange $script:DhcpStartRange `
            -EndRange $script:DhcpEndRange `
            -SubnetMask $script:DhcpSubnetMask `
            -State Active
    }

    Set-DhcpServerv4OptionValue `
        -ScopeId $script:DhcpScopeId `
        -Router $script:DhcpRouter `
        -DnsServer $script:DcIp `
        -DnsDomain $script:DomainFqdn

    Set-DhcpServerv4DnsSetting `
        -DynamicUpdates Always `
        -DeleteDnsRRonLeaseExpiry $true `
        -UpdateDnsRRForOlderClients $true
}

function Ensure-OU {
    param(
        [string]$Name,
        [string]$Path,
        [bool]$ProtectedFromAccidentalDeletion = $true
    )

    $ouDn = "OU=$Name,$Path"
    if (-not (Get-ADOrganizationalUnit -LDAPFilter "(distinguishedName=$ouDn)" -ErrorAction SilentlyContinue)) {
        New-ADOrganizationalUnit -Name $Name -Path $Path -ProtectedFromAccidentalDeletion $ProtectedFromAccidentalDeletion
    }
}

function Get-DefaultOuDefinitions {
    $rootDn = "OU=$($script:EnterpriseRootOuName),$($script:DomainDn)"

    @(
        @{ Name = $script:EnterpriseRootOuName; ParentDn = $script:DomainDn; ProtectedFromAccidentalDeletion = $true; Enabled = $true }
        @{ Name = 'Tier0'; ParentDn = $rootDn; ProtectedFromAccidentalDeletion = $true; Enabled = $true }
        @{ Name = 'Tier1'; ParentDn = $rootDn; ProtectedFromAccidentalDeletion = $true; Enabled = $true }
        @{ Name = 'Tier2'; ParentDn = $rootDn; ProtectedFromAccidentalDeletion = $true; Enabled = $true }
        @{ Name = 'Users'; ParentDn = $rootDn; ProtectedFromAccidentalDeletion = $true; Enabled = $true }
        @{ Name = 'Workstations'; ParentDn = $rootDn; ProtectedFromAccidentalDeletion = $true; Enabled = $true }
        @{ Name = 'Servers'; ParentDn = $rootDn; ProtectedFromAccidentalDeletion = $true; Enabled = $true }
        @{ Name = 'Groups'; ParentDn = $rootDn; ProtectedFromAccidentalDeletion = $true; Enabled = $true }
        @{ Name = 'ServiceAccounts'; ParentDn = $rootDn; ProtectedFromAccidentalDeletion = $true; Enabled = $true }
        @{ Name = 'Admins'; ParentDn = $rootDn; ProtectedFromAccidentalDeletion = $true; Enabled = $true }
        @{ Name = 'Sites'; ParentDn = $rootDn; ProtectedFromAccidentalDeletion = $true; Enabled = $true }
        @{ Name = 'Staging'; ParentDn = $rootDn; ProtectedFromAccidentalDeletion = $true; Enabled = $true }
        @{ Name = 'Quarantine'; ParentDn = $rootDn; ProtectedFromAccidentalDeletion = $true; Enabled = $true }
        @{ Name = 'Corporate'; ParentDn = "OU=Users,$rootDn"; ProtectedFromAccidentalDeletion = $true; Enabled = $true }
        @{ Name = 'Regional'; ParentDn = "OU=Users,$rootDn"; ProtectedFromAccidentalDeletion = $true; Enabled = $true }
        @{ Name = 'Contractors'; ParentDn = "OU=Users,$rootDn"; ProtectedFromAccidentalDeletion = $true; Enabled = $true }
        @{ Name = 'PrivilegedExcluded'; ParentDn = "OU=Users,$rootDn"; ProtectedFromAccidentalDeletion = $true; Enabled = $true }
        @{ Name = 'Disabled'; ParentDn = "OU=Users,$rootDn"; ProtectedFromAccidentalDeletion = $true; Enabled = $true }
        @{ Name = 'AMER'; ParentDn = "OU=Workstations,$rootDn"; ProtectedFromAccidentalDeletion = $true; Enabled = $true }
        @{ Name = 'EMEA'; ParentDn = "OU=Workstations,$rootDn"; ProtectedFromAccidentalDeletion = $true; Enabled = $true }
        @{ Name = 'APAC'; ParentDn = "OU=Workstations,$rootDn"; ProtectedFromAccidentalDeletion = $true; Enabled = $true }
        @{ Name = 'Kiosks'; ParentDn = "OU=Workstations,$rootDn"; ProtectedFromAccidentalDeletion = $true; Enabled = $true }
        @{ Name = 'VDI'; ParentDn = "OU=Workstations,$rootDn"; ProtectedFromAccidentalDeletion = $true; Enabled = $true }
        @{ Name = 'Quarantine'; ParentDn = "OU=Workstations,$rootDn"; ProtectedFromAccidentalDeletion = $true; Enabled = $true }
        @{ Name = 'Infrastructure'; ParentDn = "OU=Servers,$rootDn"; ProtectedFromAccidentalDeletion = $true; Enabled = $true }
        @{ Name = 'Applications'; ParentDn = "OU=Servers,$rootDn"; ProtectedFromAccidentalDeletion = $true; Enabled = $true }
        @{ Name = 'Regional'; ParentDn = "OU=Servers,$rootDn"; ProtectedFromAccidentalDeletion = $true; Enabled = $true }
        @{ Name = 'JumpHosts'; ParentDn = "OU=Servers,$rootDn"; ProtectedFromAccidentalDeletion = $true; Enabled = $true }
        @{ Name = 'RoleBased'; ParentDn = "OU=Groups,$rootDn"; ProtectedFromAccidentalDeletion = $true; Enabled = $true }
        @{ Name = 'ResourceBased'; ParentDn = "OU=Groups,$rootDn"; ProtectedFromAccidentalDeletion = $true; Enabled = $true }
        @{ Name = 'MailEnabled'; ParentDn = "OU=Groups,$rootDn"; ProtectedFromAccidentalDeletion = $true; Enabled = $true }
        @{ Name = 'Delegation'; ParentDn = "OU=Groups,$rootDn"; ProtectedFromAccidentalDeletion = $true; Enabled = $true }
        @{ Name = 'Tier0'; ParentDn = "OU=ServiceAccounts,$rootDn"; ProtectedFromAccidentalDeletion = $true; Enabled = $true }
        @{ Name = 'Tier1'; ParentDn = "OU=ServiceAccounts,$rootDn"; ProtectedFromAccidentalDeletion = $true; Enabled = $true }
        @{ Name = 'Tier2'; ParentDn = "OU=ServiceAccounts,$rootDn"; ProtectedFromAccidentalDeletion = $true; Enabled = $true }
        @{ Name = 'Applications'; ParentDn = "OU=ServiceAccounts,$rootDn"; ProtectedFromAccidentalDeletion = $true; Enabled = $true }
        @{ Name = 'Tier0'; ParentDn = "OU=Admins,$rootDn"; ProtectedFromAccidentalDeletion = $true; Enabled = $true }
        @{ Name = 'Tier1'; ParentDn = "OU=Admins,$rootDn"; ProtectedFromAccidentalDeletion = $true; Enabled = $true }
        @{ Name = 'Tier2'; ParentDn = "OU=Admins,$rootDn"; ProtectedFromAccidentalDeletion = $true; Enabled = $true }
        @{ Name = 'EmergencyAccess'; ParentDn = "OU=Admins,$rootDn"; ProtectedFromAccidentalDeletion = $true; Enabled = $true }
        @{ Name = 'AMER'; ParentDn = "OU=Sites,$rootDn"; ProtectedFromAccidentalDeletion = $true; Enabled = $true }
        @{ Name = 'EMEA'; ParentDn = "OU=Sites,$rootDn"; ProtectedFromAccidentalDeletion = $true; Enabled = $true }
        @{ Name = 'APAC'; ParentDn = "OU=Sites,$rootDn"; ProtectedFromAccidentalDeletion = $true; Enabled = $true }
        @{ Name = 'AdminGroups'; ParentDn = "OU=Tier0,$rootDn"; ProtectedFromAccidentalDeletion = $true; Enabled = $true }
        @{ Name = 'Delegation'; ParentDn = "OU=Tier0,$rootDn"; ProtectedFromAccidentalDeletion = $true; Enabled = $true }
        @{ Name = 'PrivilegedRoles'; ParentDn = "OU=Tier0,$rootDn"; ProtectedFromAccidentalDeletion = $true; Enabled = $true }
        @{ Name = 'AdminGroups'; ParentDn = "OU=Tier1,$rootDn"; ProtectedFromAccidentalDeletion = $true; Enabled = $true }
        @{ Name = 'Delegation'; ParentDn = "OU=Tier1,$rootDn"; ProtectedFromAccidentalDeletion = $true; Enabled = $true }
        @{ Name = 'PrivilegedRoles'; ParentDn = "OU=Tier1,$rootDn"; ProtectedFromAccidentalDeletion = $true; Enabled = $true }
        @{ Name = 'AdminGroups'; ParentDn = "OU=Tier2,$rootDn"; ProtectedFromAccidentalDeletion = $true; Enabled = $true }
        @{ Name = 'Delegation'; ParentDn = "OU=Tier2,$rootDn"; ProtectedFromAccidentalDeletion = $true; Enabled = $true }
        @{ Name = 'PrivilegedRoles'; ParentDn = "OU=Tier2,$rootDn"; ProtectedFromAccidentalDeletion = $true; Enabled = $true }
    )
}

function Get-OuDefinitions {
    if (-not [string]::IsNullOrWhiteSpace($script:OuTemplateCsvPath)) {
        if (-not (Test-Path -LiteralPath $script:OuTemplateCsvPath)) {
            throw "OU template CSV '$($script:OuTemplateCsvPath)' was not found."
        }

        return @(Import-Csv -LiteralPath $script:OuTemplateCsvPath | Where-Object {
            $_.Enabled -match '^(?i:true|1|yes)$'
        })
    }

    return @(Get-DefaultOuDefinitions)
}

function Ensure-OuHierarchy {
    $definitions = @(Get-OuDefinitions)
    foreach ($definition in $definitions) {
        $protected = $true
        if ($definition.PSObject.Properties.Name -contains 'ProtectedFromAccidentalDeletion') {
            $protected = $definition.ProtectedFromAccidentalDeletion -match '^(?i:true|1|yes)$'
        }

        Ensure-OU -Name $definition.Name -Path $definition.ParentDn -ProtectedFromAccidentalDeletion $protected
    }
}

Resolve-Inputs
Ensure-Module -Name ActiveDirectory
Ensure-Module -Name DhcpServer
Ensure-Module -Name DnsServer

$summary = [pscustomobject]@{
    DomainFqdn = $script:DomainFqdn
    DomainDn = $script:DomainDn
    DcFqdn = $script:DcFqdn
    DcIp = $script:DcIp
    UpnSuffix = $script:UpnSuffix
    DnsForwarders = ($script:DnsForwarders -join ', ')
    ServerReverseNetworkId = $script:ServerReverseNetworkId
    WorkstationReverseNetworkId = $script:WorkstationReverseNetworkId
    DhcpScopeId = $script:DhcpScopeId
    DhcpRouter = $script:DhcpRouter
    EnterpriseRootOuName = $script:EnterpriseRootOuName
    OuTemplateCsvPath = $(if ([string]::IsNullOrWhiteSpace($script:OuTemplateCsvPath)) { 'Built-in default hierarchy' } else { $script:OuTemplateCsvPath })
    ValidateOnly = [bool]$ValidateOnly
}

$summary | Format-List | Out-String | Write-Output

if ($ValidateOnly) {
    Write-Output 'Validation mode only. Post-promotion baseline was not applied.'
    return
}

Ensure-UpnSuffix
Ensure-DnsForwarders
Ensure-DnsZone -NetworkId $script:ServerReverseNetworkId
Ensure-DnsZone -NetworkId $script:WorkstationReverseNetworkId
Ensure-DhcpAuthorization
Ensure-DhcpScope
Ensure-OuHierarchy

Write-Output 'Post-promotion baseline completed successfully.'
