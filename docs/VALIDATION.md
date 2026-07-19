# Publication gate

This repository is intentionally smaller than the internal runbook repository.

| Rule | Required evidence |
| --- | --- |
| Live deployment | Script's workflow completed in the lab |
| Functional validation | Resulting role/service was queried or used by a real client |
| Safe inputs | Passwords use secure prompts; all identifiers are parameters or `example` values |
| Public hygiene | No secrets, internal addresses, domain names, account names, or exports |
| Syntax | PowerShell parser succeeds |

The following workflows met this gate in the source lab: AD DS promotion and post-promotion services, OU/Sites configuration, computer and user GPO baselines, file services, and workstation domain join.
