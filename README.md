# GNTECH Validated Deployment Scripts

Parameter-driven infrastructure scripts whose underlying workflows were live-validated in the GNTECH Proxmox lab. This public distribution contains no passwords, access tokens, internal addresses, production domain names, or customer topology.

## What this repository is

The scripts are reusable implementation templates. Every value that identifies an environment uses the `example.corp` sample namespace or is requested at run time. Passwords are always requested as `SecureString` values; do not add secrets to a command line, a source file, or a repository.

Each script is idempotent where the validated workflow requires it and exposes `-ValidateOnly` where a non-destructive preflight is supported.

## What this repository is not

It is not a replacement for change control or a claim that the sample values fit every network. Before a production run, supply your own values, review the script, run its validation/preflight path where provided, and test in a non-production environment.

Only workflows that have completed a real lab deployment are admitted here. Work-in-progress scripts, router exports, customer configuration, and unvalidated variants remain out of this public repository.

## Included workflows

| Order | Workflow | Script |
| --- | --- | --- |
| 01 | Initial Windows Server hostname, static IPv4, DNS, and AD DS/DNS/DHCP features | `scripts/01-Initialize-WindowsServerNetwork.ps1` |
| 02 | New Active Directory forest promotion | `scripts/02-Promote-ADForest.ps1` |
| 03 | DNS, DHCP, reverse zones, and full OU post-promotion baseline | `scripts/03-Configure-ADPostPromotion.ps1` |
| 04 | Active Directory Sites and Services subnets | `scripts/04-Configure-ADSites.ps1` |
| 05 | Computer baseline GPOs | `scripts/05-Configure-ComputerBaselineGpo.ps1` |
| 06 | User baseline GPO | `scripts/06-Configure-UserBaselineGpo.ps1` |
| 07 | File-server hostname/network/domain onboarding | `scripts/07-Deploy-FileServerStage1.ps1` |
| 08 | File-service access groups | `scripts/08-Create-FileServiceGroups.ps1` |
| 09 | SMB shares and NTFS permissions | `scripts/09-Configure-FileShares.ps1` |
| 10 | Domain workstation validation and join | `scripts/10-Join-DomainWorkstation.ps1` |

## Safe usage pattern

1. Clone or copy this repository to an administrator-controlled location.
2. Copy the intended script to the target server, for example `C:\DeploymentScripts`.
3. Open an elevated PowerShell session and review its parameters with `Get-Help .\script.ps1 -Full` or the `param` block.
4. Use the `example.corp` values only as a syntax example; replace them with your environment values.
5. Use `-ValidateOnly` where it is available, then run the intended change during an approved window.

Example forest promotion:

```powershell
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force
.\02-Promote-ADForest.ps1 -DomainName 'corp.example' -NetBIOSName 'EXAMPLE'
```

The script securely requests both the local Administrator password and the DSRM password.

## OU template

`templates/ou-baseline.csv` contains the complete 52-OU hierarchy validated in the source lab: enterprise root; Tier0/1/2; Users; Workstations; Servers; Groups; ServiceAccounts; Admins; Sites; Staging; Quarantine; and their functional children. `03-Configure-ADPostPromotion.ps1` automatically uses this repository template when it runs from the `scripts` directory. Pass `-OuTemplateCsvPath` only when using your own approved CSV.

## Validation provenance

The source workflows were validated in the GNTECH Windows deployment lab before publication, with source baseline `8e50f77` of the private runbook repository. Public values have been sanitized to examples. The PowerShell parser is run for every published `.ps1` file before release.

## License and support

See [LICENSE](LICENSE), [SECURITY.md](SECURITY.md), and [CONTRIBUTING.md](CONTRIBUTING.md).
