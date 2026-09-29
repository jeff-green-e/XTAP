# Cross-Tenant Calendar Sharing: EWS to M365 XTAP

Moving cross-tenant Free/Busy, MailTips, and Calendar Sharing between operating-company tenants off Exchange Web Services (EWS) and onto Microsoft 365 Cross-Tenant Access Policy ahead of the EWS retirement (soft block October 1, 2026; hard shutdown April 1, 2027).

| Doc | Purpose |
| --- | --- |
| 1. [How It Works](01-how-it-works.md) | Start here. Concepts and diagrams, and **which runbook to use**: what's changing, the three layers, inbound-per-tenant model, old-to-new setting map |
| 2. [Migrate Existing Sharing](02-migrate-existing-sharing.md) | Runbook for partners that already share through EWS-era config (Organization Relationship, Sharing Policy, Availability Address Space): discovery, setup, cutover and validation, cleanup, per-pairing tracking |
| 3. [Set Up New Sharing](03-set-up-new-sharing.md) | Runbook for partners that don't share yet (no EWS-era config on either side): choosing capabilities, setup on each side, validation, removal |
| [Enable-XtapPartner.ps1](Enable-XtapPartner.ps1) | Script for the PowerShell steps of either runbook: sign-in, M365 Collaboration trust (Layer 2), and capability grants (Layer 3; Free/Busy times only by default). Use it alongside a runbook, not instead of one. It never touches cross-tenant access or trust settings (Layer 1), which are done in the Entra admin center. Run `Get-Help .\Enable-XtapPartner.ps1 -Full` for usage. |
| [Test-XtapPartner.ps1](Test-XtapPartner.ps1) | Read-only check of one partner, or every partner, in a tenant: partner entry, trust settings, M365 Collaboration trust, capabilities, and any tenant-wide default grants. PASS/WARN/FAIL report, optional CSV. Read-only; a Global Reader can run it once an admin has approved its permissions. Doesn't check old EWS-era config or prove Free/Busy works for users. |

The manual PowerShell snippets in 02 and 03 mirror the two scripts. If you change one, update the other.

Diagrams are standalone SVG files in `images/` and render in both GitHub and Azure DevOps; `images/` also holds one screenshot (PNG) of unblocking a downloaded script.
