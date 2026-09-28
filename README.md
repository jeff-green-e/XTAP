# Cross-Tenant Calendar Sharing: EWS to M365 XTAP

Moving cross-tenant Free/Busy, MailTips, and Calendar Sharing between operating-company tenants off Exchange Web Services (EWS) and onto Microsoft 365 Cross-Tenant Access Policy ahead of the EWS retirement (soft block October 1, 2026; hard shutdown April 1, 2027).

| Doc | Purpose |
| --- | --- |
| 1. [How It Works](01-how-it-works.md) | Start here. Concepts and diagrams: what's changing, the three layers, inbound-per-tenant model, old-to-new setting map |
| 2. [Migration Checklist](02-migration-checklist.md) | Runbook: discovery, prerequisites, Graph REST calls in PowerShell, cutover and validation, cleanup, per-pairing tracking |
| 3. [New Partner Setup](03-new-partner-setup.md) | Runbook for net-new sharing where no EWS-era config exists: choosing capabilities, setup on each side, validation, removal |
| [Enable-XtapPartner.ps1](Enable-XtapPartner.ps1) | Script for the PowerShell steps of either runbook: sign-in, M365 Collaboration trust (Layer 2), and one capability grant (Layer 3). Use it alongside a runbook, not instead of one. It never touches cross-tenant access or trust settings (Layer 1), which are done in the Entra admin center. Run `Get-Help .\Enable-XtapPartner.ps1 -Full` for usage. |

Diagrams are standalone SVG files in `images/` and render in both GitHub and Azure DevOps.
