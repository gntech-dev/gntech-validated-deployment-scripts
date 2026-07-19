param(
    [string]$DomainName,
    [string]$NetBIOSName,
    [switch]$InstallDns = $true,
    [switch]$NoRebootOnCompletion,
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

function Read-RequiredSecret {
    param(
        [string]$Prompt
    )

    try {
        return (Read-Host -Prompt $Prompt -AsSecureString)
    }
    catch {
        throw "A secure value for '$Prompt' is required when running non-interactively."
    }
}

function Convert-SecureStringToLength {
    param(
        [Security.SecureString]$SecureValue
    )

    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureValue)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr).Length
    }
    finally {
        if ($bstr -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    }
}

function Resolve-Inputs {
    $script:DomainName = if ([string]::IsNullOrWhiteSpace($DomainName)) {
        Read-RequiredValue -Prompt 'Forest/domain FQDN' -DefaultValue 'example.corp'
    }
    else {
        $DomainName.Trim()
    }

    $script:NetBIOSName = if ([string]::IsNullOrWhiteSpace($NetBIOSName)) {
        Read-RequiredValue -Prompt 'NetBIOS name' -DefaultValue 'EXAMPLE'
    }
    else {
        $NetBIOSName.Trim()
    }

    if (-not $ValidateOnly) {
        $script:LocalAdministratorPassword = Read-RequiredSecret `
            -Prompt 'Local Administrator password'

        $script:SafeModeAdministratorPassword = Read-RequiredSecret `
            -Prompt 'DSRM password'
    }
}

function Test-Prerequisites {
    $computerSystem = Get-CimInstance Win32_ComputerSystem
    if ($computerSystem.PartOfDomain) {
        throw "Server is already joined to domain '$($computerSystem.Domain)'."
    }

    $addsFeature = Get-WindowsFeature AD-Domain-Services
    if ($addsFeature.InstallState -ne 'Installed') {
        throw 'AD-Domain-Services feature is not installed.'
    }

    $localAdministrator = Get-LocalUser | Where-Object SID -like 'S-1-5-21-*-500' | Select-Object -First 1
    if (-not $localAdministrator) {
        throw 'Built-in local Administrator account with RID 500 was not found.'
    }

    if (-not $ValidateOnly) {
        $localAdminLength = Convert-SecureStringToLength -SecureValue $script:LocalAdministratorPassword
        $safeModeLength = Convert-SecureStringToLength -SecureValue $script:SafeModeAdministratorPassword

        if ($localAdminLength -lt 12) {
            throw 'Local Administrator password must be at least 12 characters.'
        }

        if ($safeModeLength -lt 12) {
            throw 'DSRM password must be at least 12 characters.'
        }
    }

    [pscustomobject]@{
        Hostname = $env:COMPUTERNAME
        DomainName = $script:DomainName
        NetBIOSName = $script:NetBIOSName
        PartOfDomain = $computerSystem.PartOfDomain
        AddsInstalled = $addsFeature.InstallState
        InstallDns = [bool]$InstallDns
        NoRebootOnCompletion = [bool]$NoRebootOnCompletion
        ValidateOnly = [bool]$ValidateOnly
    }
}

Resolve-Inputs
$summary = Test-Prerequisites
$summary | Format-List | Out-String | Write-Output

if ($ValidateOnly) {
    Write-Output 'Validation mode only. Promotion was not started.'
    return
}

$localAdministrator = Get-LocalUser | Where-Object SID -like 'S-1-5-21-*-500' | Select-Object -First 1
$localAdministrator | Set-LocalUser -Password $script:LocalAdministratorPassword

$promotionParams = @{
    DomainName                    = $script:DomainName
    DomainNetbiosName             = $script:NetBIOSName
    SafeModeAdministratorPassword = $script:SafeModeAdministratorPassword
    InstallDns                    = [bool]$InstallDns
    Force                         = $true
    NoRebootOnCompletion          = [bool]$NoRebootOnCompletion
}

Install-ADDSForest @promotionParams
