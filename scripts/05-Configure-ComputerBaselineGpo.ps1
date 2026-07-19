param(
    [string]$DomainFqdn,
    [string]$DomainDn,
    [string]$EnterpriseRootOuDn,
    [string]$DomainControllersDn,
    [string]$ServersOuDn,
    [string]$WorkstationsOuDn,
    [string]$DcBaselineGpoName,
    [string]$ServerBaselineGpoName,
    [string]$WorkstationBaselineGpoName,
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
    if ($DefaultValue) { $fullPrompt = "$Prompt [$DefaultValue]" }

    while ($true) {
        $value = Read-Host -Prompt $fullPrompt
        if (-not [string]::IsNullOrWhiteSpace($value)) { return $value.Trim() }
        if (-not [string]::IsNullOrWhiteSpace($DefaultValue)) { return $DefaultValue }
    }
}

function Resolve-Inputs {
    $script:DomainFqdn = if ([string]::IsNullOrWhiteSpace($DomainFqdn)) { Read-RequiredValue 'Domain FQDN' 'example.corp' } else { $DomainFqdn.Trim() }
    $script:DomainDn = if ([string]::IsNullOrWhiteSpace($DomainDn)) { Read-RequiredValue 'Domain DN' 'DC=example,DC=corp' } else { $DomainDn.Trim() }
    $script:EnterpriseRootOuDn = if ([string]::IsNullOrWhiteSpace($EnterpriseRootOuDn)) { Read-RequiredValue 'Enterprise root OU DN' 'OU=Example,DC=example,DC=corp' } else { $EnterpriseRootOuDn.Trim() }
    $script:DomainControllersDn = if ([string]::IsNullOrWhiteSpace($DomainControllersDn)) { Read-RequiredValue 'Domain Controllers OU DN' 'OU=Domain Controllers,DC=example,DC=corp' } else { $DomainControllersDn.Trim() }
    $script:ServersOuDn = if ([string]::IsNullOrWhiteSpace($ServersOuDn)) { Read-RequiredValue 'Servers OU DN' 'OU=Servers,OU=Example,DC=example,DC=corp' } else { $ServersOuDn.Trim() }
    $script:WorkstationsOuDn = if ([string]::IsNullOrWhiteSpace($WorkstationsOuDn)) { Read-RequiredValue 'Workstations OU DN' 'OU=Workstations,OU=Example,DC=example,DC=corp' } else { $WorkstationsOuDn.Trim() }
    $script:DcBaselineGpoName = if ([string]::IsNullOrWhiteSpace($DcBaselineGpoName)) { Read-RequiredValue 'DC baseline GPO name' 'GPO-DC-Baseline' } else { $DcBaselineGpoName.Trim() }
    $script:ServerBaselineGpoName = if ([string]::IsNullOrWhiteSpace($ServerBaselineGpoName)) { Read-RequiredValue 'Server baseline GPO name' 'GPO-Servers-Baseline' } else { $ServerBaselineGpoName.Trim() }
    $script:WorkstationBaselineGpoName = if ([string]::IsNullOrWhiteSpace($WorkstationBaselineGpoName)) { Read-RequiredValue 'Workstation baseline GPO name' 'GPO-Workstations-Baseline' } else { $WorkstationBaselineGpoName.Trim() }
}

function Ensure-Module {
    param([string]$Name)
    Import-Module $Name
}

function Ensure-Gpo {
    param(
        [string]$Name,
        [string]$Comment
    )

    $gpo = Get-GPO -Name $Name -ErrorAction SilentlyContinue
    if (-not $gpo) {
        $gpo = New-GPO -Name $Name -Comment $Comment
    }
    return $gpo
}

function Ensure-GpoLink {
    param(
        [string]$Name,
        [string]$Target
    )

    $existingLink = @((Get-GPInheritance -Target $Target).GpoLinks | Where-Object DisplayName -eq $Name)
    if ($existingLink.Count -eq 0) {
        New-GPLink -Name $Name -Target $Target -LinkEnabled Yes | Out-Null
    }
}

function Set-BaselineRegistryValue {
    param(
        [string]$GpoName,
        [string]$Key,
        [string]$ValueName,
        [string]$Type,
        [object]$Value
    )

    Set-GPRegistryValue -Name $GpoName -Key $Key -ValueName $ValueName -Type $Type -Value $Value | Out-Null
}

Resolve-Inputs
Ensure-Module -Name ActiveDirectory
Ensure-Module -Name GroupPolicy

$summary = [pscustomobject]@{
    DomainFqdn = $script:DomainFqdn
    DomainDn = $script:DomainDn
    EnterpriseRootOuDn = $script:EnterpriseRootOuDn
    DomainControllersDn = $script:DomainControllersDn
    ServersOuDn = $script:ServersOuDn
    WorkstationsOuDn = $script:WorkstationsOuDn
    DcBaselineGpoName = $script:DcBaselineGpoName
    ServerBaselineGpoName = $script:ServerBaselineGpoName
    WorkstationBaselineGpoName = $script:WorkstationBaselineGpoName
    ValidateOnly = [bool]$ValidateOnly
}

$summary | Format-List | Out-String | Write-Output

if ($ValidateOnly) {
    Write-Output 'Validation mode only. GPO baseline was not applied.'
    return
}

Set-ADDefaultDomainPasswordPolicy `
    -Identity $script:DomainFqdn `
    -ComplexityEnabled $true `
    -MinPasswordLength 14 `
    -PasswordHistoryCount 24 `
    -MinPasswordAge 1.00:00:00 `
    -MaxPasswordAge 90.00:00:00 `
    -LockoutThreshold 10 `
    -LockoutDuration 0.00:15:00 `
    -LockoutObservationWindow 0.00:15:00

$definitions = @(
    @{ Name = $script:DcBaselineGpoName; Comment = 'Baseline for domain controllers'; Target = $script:DomainControllersDn },
    @{ Name = $script:ServerBaselineGpoName; Comment = 'Baseline for member servers'; Target = $script:ServersOuDn },
    @{ Name = $script:WorkstationBaselineGpoName; Comment = 'Baseline for workstation endpoints'; Target = $script:WorkstationsOuDn }
)

foreach ($definition in $definitions) {
    Ensure-Gpo -Name $definition.Name -Comment $definition.Comment | Out-Null
    Ensure-GpoLink -Name $definition.Name -Target $definition.Target
}

foreach ($gpoName in @($script:DcBaselineGpoName, $script:ServerBaselineGpoName)) {
    Set-BaselineRegistryValue -GpoName $gpoName -Key 'HKLM\Software\Policies\Microsoft\Windows\EventLog\Application' -ValueName 'MaxSize' -Type DWord -Value 131072
    Set-BaselineRegistryValue -GpoName $gpoName -Key 'HKLM\Software\Policies\Microsoft\Windows\EventLog\Security' -ValueName 'MaxSize' -Type DWord -Value 262144
    Set-BaselineRegistryValue -GpoName $gpoName -Key 'HKLM\Software\Policies\Microsoft\Windows\EventLog\System' -ValueName 'MaxSize' -Type DWord -Value 131072
}

Set-BaselineRegistryValue -GpoName $script:WorkstationBaselineGpoName -Key 'HKLM\Software\Policies\Microsoft\Windows\EventLog\Application' -ValueName 'MaxSize' -Type DWord -Value 65536
Set-BaselineRegistryValue -GpoName $script:WorkstationBaselineGpoName -Key 'HKLM\Software\Policies\Microsoft\Windows\EventLog\Security' -ValueName 'MaxSize' -Type DWord -Value 131072
Set-BaselineRegistryValue -GpoName $script:WorkstationBaselineGpoName -Key 'HKLM\Software\Policies\Microsoft\Windows\EventLog\System' -ValueName 'MaxSize' -Type DWord -Value 65536

foreach ($gpoName in @($script:DcBaselineGpoName, $script:ServerBaselineGpoName, $script:WorkstationBaselineGpoName)) {
    Set-BaselineRegistryValue -GpoName $gpoName -Key 'HKLM\Software\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging' -ValueName 'EnableScriptBlockLogging' -Type DWord -Value 1
}

Write-Output 'GPO baseline completed successfully.'
