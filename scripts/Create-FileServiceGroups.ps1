param(
    [string]$GroupsOuDn,
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
    $script:GroupsOuDn = if ([string]::IsNullOrWhiteSpace($GroupsOuDn)) {
        Read-RequiredValue 'Groups OU DN' 'OU=Groups,OU=Example,DC=example,DC=corp'
    } else {
        $GroupsOuDn.Trim()
    }
}

function Ensure-Module {
    param([string]$Name)
    Import-Module $Name
}

function Ensure-Group {
    param(
        [string]$Name,
        [string]$Description
    )

    $existing = Get-ADGroup -LDAPFilter "(cn=$Name)" -SearchBase $script:GroupsOuDn -ErrorAction SilentlyContinue
    if ($existing) {
        return [pscustomobject]@{ Name = $Name; Action = 'Exists' }
    }

    if (-not $ValidateOnly) {
        New-ADGroup `
            -Name $Name `
            -SamAccountName $Name `
            -GroupScope DomainLocal `
            -GroupCategory Security `
            -Path $script:GroupsOuDn `
            -Description $Description | Out-Null
    }

    [pscustomobject]@{ Name = $Name; Action = $(if ($ValidateOnly) { 'Planned' } else { 'Created' }) }
}

Resolve-Inputs
Ensure-Module -Name ActiveDirectory

$definitions = @(
    @{ Name = 'DL-FS01-Public-RW'; Description = 'Modify access to FS01 Public share' },
    @{ Name = 'DL-FS01-Departments-IT-RW'; Description = 'Modify access to FS01 Departments IT folder' },
    @{ Name = 'DL-FS01-Departments-Finance-RW'; Description = 'Modify access to FS01 Departments Finance folder' },
    @{ Name = 'DL-FS01-Backups-RW'; Description = 'Modify access to FS01 Backups share' }
)

$summary = $definitions | ForEach-Object {
    [pscustomobject]@{
        Name = $_.Name
        Description = $_.Description
        Path = $script:GroupsOuDn
    }
}
$summary | Format-Table -AutoSize | Out-String | Write-Output

$results = foreach ($definition in $definitions) {
    Ensure-Group -Name $definition.Name -Description $definition.Description
}

$results | Format-Table -AutoSize | Out-String | Write-Output

if ($ValidateOnly) {
    Write-Output 'Validation mode only. FS01 groups were not created.'
} else {
    Write-Output 'FS01 groups completed successfully.'
}
