param(
    [string]$UsersOuDn,
    [string]$UserBaselineGpoName,
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
    $script:UsersOuDn = if ([string]::IsNullOrWhiteSpace($UsersOuDn)) { Read-RequiredValue 'Users OU DN' 'OU=Users,OU=Example,DC=example,DC=corp' } else { $UsersOuDn.Trim() }
    $script:UserBaselineGpoName = if ([string]::IsNullOrWhiteSpace($UserBaselineGpoName)) { Read-RequiredValue 'User baseline GPO name' 'GPO-Users-Baseline' } else { $UserBaselineGpoName.Trim() }
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

function Set-UserRegistryValue {
    param(
        [string]$Key,
        [string]$ValueName,
        [string]$Type,
        [object]$Value
    )

    Set-GPRegistryValue `
        -Name $script:UserBaselineGpoName `
        -Key $Key `
        -ValueName $ValueName `
        -Type $Type `
        -Value $Value | Out-Null
}

Resolve-Inputs
Ensure-Module -Name GroupPolicy

$summary = [pscustomobject]@{
    UsersOuDn = $script:UsersOuDn
    UserBaselineGpoName = $script:UserBaselineGpoName
    ValidateOnly = [bool]$ValidateOnly
}

$summary | Format-List | Out-String | Write-Output

if ($ValidateOnly) {
    Write-Output 'Validation mode only. User baseline GPO was not applied.'
    return
}

Ensure-Gpo -Name $script:UserBaselineGpoName -Comment 'Baseline for standard user settings' | Out-Null
Ensure-GpoLink -Name $script:UserBaselineGpoName -Target $script:UsersOuDn

# Show file extensions in Explorer.
Set-UserRegistryValue `
    -Key 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' `
    -ValueName 'HideFileExt' `
    -Type DWord `
    -Value 0

# Do not hide hidden files for standard users yet; keep baseline low-risk.

# Remove the Windows consumer "News and interests" style taskbar feed.
Set-UserRegistryValue `
    -Key 'HKCU\Software\Microsoft\Windows\CurrentVersion\Feeds' `
    -ValueName 'ShellFeedsTaskbarViewMode' `
    -Type DWord `
    -Value 2

# Block Control Panel and Settings access as a visible, user-scoped baseline.
Set-UserRegistryValue `
    -Key 'HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer' `
    -ValueName 'NoControlPanel' `
    -Type DWord `
    -Value 1

Write-Output 'User baseline GPO completed successfully.'
