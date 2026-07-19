# GNTECH Validated Deployment Scripts

Parameter-driven infrastructure scripts whose underlying workflows were live-validated in the GNTECH Proxmox lab. This public distribution contains no passwords, access tokens, internal addresses, production domain names, or customer topology.

## What this repository is

The scripts are reusable implementation templates. Every value that identifies an environment uses the `example.corp` sample namespace or is requested at run time. Passwords are always requested as `SecureString` values; do not add secrets to a command line, a source file, or a repository.

Each script is idempotent where the validated workflow requires it and exposes `-ValidateOnly` where a non-destructive preflight is supported.

## What this repository is not

It is not a replacement for change control or a claim that the sample values fit every network. Before a production run, supply your own values, review the script, run its validation/preflight path where provided, and test in a non-production environment.

Only workflows that have completed a real lab deployment are admitted here. Work-in-progress scripts, router exports, customer configuration, and unvalidated variants remain out of this public repository.

## Included workflows

| Workflow | Script |
| --- | --- |
| Initial Windows Server hostname, static IPv4, DNS, and AD DS/DNS/DHCP features | `scripts/Initialize-WindowsServerNetwork.ps1` |
| New Active Directory forest promotion | `scripts/Promote-ADForest.ps1` |
| DNS, DHCP, reverse zones, and OU post-promotion baseline | `scripts/Configure-ADPostPromotion.ps1` |
| Active Directory Sites and Services subnets | `scripts/Configure-ADSites.ps1` |
| Computer baseline GPOs | `scripts/Configure-ComputerBaselineGpo.ps1` |
| User baseline GPO | `scripts/Configure-UserBaselineGpo.ps1` |
| File-server hostname/network/domain onboarding | `scripts/Deploy-FileServerStage1.ps1` |
| File-service access groups and SMB shares | `scripts/Create-FileServiceGroups.ps1`, `scripts/Configure-FileShares.ps1` |
| Domain workstation validation and join | `scripts/Join-DomainWorkstation.ps1` |

## Safe usage pattern

1. Clone or copy this repository to an administrator-controlled location.
2. Copy the intended script to the target server, for example `C:\DeploymentScripts`.
3. Open an elevated PowerShell session and review its parameters with `Get-Help .\script.ps1 -Full` or the `param` block.
4. Use the `example.corp` values only as a syntax example; replace them with your environment values.
5. Use `-ValidateOnly` where it is available, then run the intended change during an approved window.

Example forest promotion:

```powershell
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force
.\Promote-ADForest.ps1 -DomainName 'corp.example' -NetBIOSName 'EXAMPLE'
```

The script securely requests both the local Administrator password and the DSRM password.

## OU template

`templates/ou-baseline.csv` is an editable OU hierarchy sample for `Configure-ADPostPromotion.ps1`.

## Validation provenance

The source workflows were validated in the GNTECH Windows deployment lab before publication, with source baseline `8e50f77` of the private runbook repository. Public values have been sanitized to examples. The PowerShell parser is run for every published `.ps1` file before release.

## License and support

See [LICENSE](LICENSE), [SECURITY.md](SECURITY.md), and [CONTRIBUTING.md](CONTRIBUTING.md).
