[CmdletBinding()]
param(
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9 _-]{0,63}$')]
    [string]$SiteName = 'HQ',
    [string]$Location = 'Headquarters',
    [string[]]$Subnets = @(
        '10.20.10.0/24',
        '10.20.20.0/24',
        '10.20.30.0/24',
        '10.20.40.0/24',
        '10.20.50.0/24',
        '10.20.60.0/24',
        '10.20.70.0/24',
        '10.20.80.0/24',
        '10.20.90.0/24',
        '10.20.100.0/24',
        '10.20.110.0/24'
    ),
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

function Get-SiteState {
    Write-Output '=== Sites ==='
    Get-ADReplicationSite -Filter * | Sort-Object Name | ForEach-Object {
        Write-Output "Site: $($_.Name) / DN=$($_.DistinguishedName)"
    }
    Write-Output '=== Subnets ==='
    Get-ADReplicationSubnet -Filter * | Sort-Object Name | ForEach-Object {
        Write-Output "Subnet: $($_.Name) / Site=$($_.Site) / Location=$($_.Location)"
    }
    Write-Output '=== Local Site Discovery ==='
    nltest /dsgetsite
}

Assert-Elevated
Import-Module ActiveDirectory

$domain = Get-ADDomain
$configDn = "CN=Configuration,$($domain.DistinguishedName)"
$defaultSiteDn = "CN=Default-First-Site-Name,CN=Sites,$configDn"

Get-SiteState
if ($ValidateOnly) {
    Write-Output 'Validation mode only. No site or subnet configuration was changed.'
    return
}

$site = Get-ADReplicationSite -Filter "Name -eq '$SiteName'" -ErrorAction SilentlyContinue
if (-not $site) {
    if (Get-ADObject -Identity $defaultSiteDn -ErrorAction SilentlyContinue) {
        Rename-ADObject -Identity $defaultSiteDn -NewName $SiteName
    }
    else {
        New-ADReplicationSite -Name $SiteName -Description 'Primary headquarters site' | Out-Null
    }
}

foreach ($subnetName in $Subnets) {
    $subnet = Get-ADReplicationSubnet -Filter "Name -eq '$subnetName'" -ErrorAction SilentlyContinue
    if ($subnet) {
        Set-ADReplicationSubnet -Identity $subnet.DistinguishedName -Site $SiteName -Location $Location
    }
    else {
        New-ADReplicationSubnet -Name $subnetName -Site $SiteName -Location $Location | Out-Null
    }
}

Write-Output '=== Result ==='
Get-SiteState

$serverSearchBase = "CN=Servers,CN=$SiteName,CN=Sites,$configDn"
$server = Get-ADObject -LDAPFilter "(cn=$env:COMPUTERNAME)" -SearchBase $serverSearchBase -ErrorAction SilentlyContinue
if (-not $server) { throw "The server object for '$env:COMPUTERNAME' was not found beneath site '$SiteName'." }
