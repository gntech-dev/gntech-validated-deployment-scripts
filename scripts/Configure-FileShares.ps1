param(
    [string]$ShareRoot,
    [string]$DomainNetbios,
    [switch]$ValidateOnly
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Assert-Elevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
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

function Resolve-Inputs {
    $script:ShareRoot = if ([string]::IsNullOrWhiteSpace($ShareRoot)) { Read-RequiredValue 'Share root path' 'C:\Shares' } else { $ShareRoot.Trim() }
    $script:DomainNetbios = if ([string]::IsNullOrWhiteSpace($DomainNetbios)) { Read-RequiredValue 'Domain NetBIOS name' 'EXAMPLE' } else { $DomainNetbios.Trim() }
}

function Ensure-Directory {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        if (-not $ValidateOnly) { New-Item -Path $Path -ItemType Directory -Force | Out-Null }
        if ($ValidateOnly) { return 'Planned' }
        return 'Created'
    }
    'Exists'
}

function Set-FolderAcl {
    param([string]$Path,[array]$Rules)
    $acl = New-Object System.Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    $inheritanceFlags = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $propagationFlags = [System.Security.AccessControl.PropagationFlags]::None
    foreach ($rule in $Rules) {
        $fsRights = [System.Security.AccessControl.FileSystemRights]$rule.Rights
        $accessType = [System.Security.AccessControl.AccessControlType]::Allow
        $aclRule = New-Object System.Security.AccessControl.FileSystemAccessRule($rule.Identity,$fsRights,$inheritanceFlags,$propagationFlags,$accessType)
        $acl.AddAccessRule($aclRule) | Out-Null
    }
    if (-not $ValidateOnly) { Set-Acl -Path $Path -AclObject $acl }
    if ($ValidateOnly) { 'Planned' } else { 'Applied' }
}

function Ensure-SmbShareState {
    param([string]$Name,[string]$Path,[string]$Description,[string[]]$FullAccess,[string[]]$ChangeAccess,[string[]]$ReadAccess,[string]$FolderEnumerationMode = 'AccessBased')
    $existing = Get-SmbShare -Name $Name -ErrorAction SilentlyContinue
    if ($existing -and $existing.Path -ne $Path) {
        throw "SMB share '$Name' exists at '$($existing.Path)' instead of '$Path'. Correct it manually before rerunning."
    }
    if (-not $ValidateOnly) {
        if (-not $existing) {
            $splat = @{ Name = $Name; Path = $Path; Description = $Description; FolderEnumerationMode = $FolderEnumerationMode }
            if ($FullAccess) { $splat.FullAccess = $FullAccess }
            if ($ChangeAccess) { $splat.ChangeAccess = $ChangeAccess }
            if ($ReadAccess) { $splat.ReadAccess = $ReadAccess }
            New-SmbShare @splat | Out-Null
        }
        else {
            Set-SmbShare -Name $Name -Description $Description -FolderEnumerationMode $FolderEnumerationMode -Force | Out-Null
            $desiredAccess = @()
            $desiredAccess += @($FullAccess | ForEach-Object { @{ Account = $_; Right = 'Full' } })
            $desiredAccess += @($ChangeAccess | ForEach-Object { @{ Account = $_; Right = 'Change' } })
            $desiredAccess += @($ReadAccess | ForEach-Object { @{ Account = $_; Right = 'Read' } })
            foreach ($entry in $desiredAccess) {
                Grant-SmbShareAccess -Name $Name -AccountName $entry.Account -AccessRight $entry.Right -Force | Out-Null
            }
        }
    }
    if ($ValidateOnly) { if ($existing) { 'Existing path validated' } else { 'Planned' } }
    elseif ($existing) { 'Reconciled' } else { 'Created' }
}

function Assert-AccountResolvable {
    param([string[]]$Identity)
    foreach ($item in $Identity) {
        try { ([System.Security.Principal.NTAccount]$item).Translate([System.Security.Principal.SecurityIdentifier]) | Out-Null }
        catch { throw "Required account or group '$item' cannot be resolved on this server." }
    }
}

Resolve-Inputs
Assert-Elevated

$departmentsRoot = Join-Path $script:ShareRoot 'Departments'
$publicRoot = Join-Path $script:ShareRoot 'Public'
$backupsRoot = Join-Path $script:ShareRoot 'Backups'
$itRoot = Join-Path $departmentsRoot 'IT'
$financeRoot = Join-Path $departmentsRoot 'Finance'

$domainUsers = "$($script:DomainNetbios)\Domain Users"
$domainAdmins = "$($script:DomainNetbios)\Domain Admins"
$builtinAdmins = 'BUILTIN\Administrators'
$systemAccount = 'NT AUTHORITY\SYSTEM'

Assert-AccountResolvable -Identity @(
    $domainUsers,$domainAdmins,$builtinAdmins,$systemAccount,
    "$($script:DomainNetbios)\DL-FS01-Departments-IT-RW",
    "$($script:DomainNetbios)\DL-FS01-Departments-Finance-RW",
    "$($script:DomainNetbios)\DL-FS01-Public-RW",
    "$($script:DomainNetbios)\DL-FS01-Backups-RW"
)

$feature = Get-WindowsFeature FS-FileServer
if (-not $feature.Installed -and -not $ValidateOnly) { Install-WindowsFeature FS-FileServer | Out-Null }
Write-Output "FS-FileServer: $(if ($feature.Installed) { 'Installed' } elseif ($ValidateOnly) { 'Missing' } else { 'Installed now' })"

$folders = @($script:ShareRoot,$departmentsRoot,$publicRoot,$backupsRoot,$itRoot,$financeRoot)
$folderResults = foreach ($folder in $folders) {
    [pscustomobject]@{ Path = $folder; Action = (Ensure-Directory -Path $folder) }
}
$folderResults | Format-Table -AutoSize | Out-String | Write-Output

Set-FolderAcl -Path $departmentsRoot -Rules @(
    @{ Identity = $systemAccount; Rights = 'FullControl' },
    @{ Identity = $builtinAdmins; Rights = 'FullControl' },
    @{ Identity = $domainAdmins; Rights = 'FullControl' },
    @{ Identity = $domainUsers; Rights = 'ReadAndExecute, Synchronize' }
)
Set-FolderAcl -Path $itRoot -Rules @(
    @{ Identity = $systemAccount; Rights = 'FullControl' },
    @{ Identity = $builtinAdmins; Rights = 'FullControl' },
    @{ Identity = $domainAdmins; Rights = 'FullControl' },
    @{ Identity = "$($script:DomainNetbios)\DL-FS01-Departments-IT-RW"; Rights = 'Modify, Synchronize' }
)
Set-FolderAcl -Path $financeRoot -Rules @(
    @{ Identity = $systemAccount; Rights = 'FullControl' },
    @{ Identity = $builtinAdmins; Rights = 'FullControl' },
    @{ Identity = $domainAdmins; Rights = 'FullControl' },
    @{ Identity = "$($script:DomainNetbios)\DL-FS01-Departments-Finance-RW"; Rights = 'Modify, Synchronize' }
)
Set-FolderAcl -Path $publicRoot -Rules @(
    @{ Identity = $systemAccount; Rights = 'FullControl' },
    @{ Identity = $builtinAdmins; Rights = 'FullControl' },
    @{ Identity = $domainAdmins; Rights = 'FullControl' },
    @{ Identity = $domainUsers; Rights = 'ReadAndExecute, Synchronize' },
    @{ Identity = "$($script:DomainNetbios)\DL-FS01-Public-RW"; Rights = 'Modify, Synchronize' }
)
Set-FolderAcl -Path $backupsRoot -Rules @(
    @{ Identity = $systemAccount; Rights = 'FullControl' },
    @{ Identity = $builtinAdmins; Rights = 'FullControl' },
    @{ Identity = $domainAdmins; Rights = 'FullControl' },
    @{ Identity = "$($script:DomainNetbios)\DL-FS01-Backups-RW"; Rights = 'Modify, Synchronize' }
)

$shareResults = @(
    [pscustomobject]@{
        Name = 'Departments'
        Action = (Ensure-SmbShareState -Name 'Departments' -Path $departmentsRoot -Description 'Departmental data root' -FullAccess @($domainAdmins) -ReadAccess @($domainUsers))
    },
    [pscustomobject]@{
        Name = 'Public'
        Action = (Ensure-SmbShareState -Name 'Public' -Path $publicRoot -Description 'Broad collaboration share' -FullAccess @($domainAdmins) -ChangeAccess @("$($script:DomainNetbios)\DL-FS01-Public-RW") -ReadAccess @($domainUsers))
    },
    [pscustomobject]@{
        Name = 'Backups'
        Action = (Ensure-SmbShareState -Name 'Backups' -Path $backupsRoot -Description 'Backup staging share' -FullAccess @($domainAdmins) -ChangeAccess @("$($script:DomainNetbios)\DL-FS01-Backups-RW"))
    }
)
$shareResults | Format-Table -AutoSize | Out-String | Write-Output

if ($ValidateOnly) {
    Write-Output 'Validation mode only. FS01 share configuration was not applied.'
} else {
    Write-Output 'FS01 share configuration completed successfully.'
}
