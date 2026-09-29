# Cross-Tenant Calendar Sharing: EWS to M365 XTAP

Moving cross-tenant Free/Busy, MailTips, and Calendar Sharing between operating-company tenants off Exchange Web Services (EWS) and onto Microsoft 365 Cross-Tenant Access Policy ahead of the EWS retirement (soft block October 1, 2026; hard shutdown April 1, 2027).

| Doc | Purpose |
| --- | --- |
| 1. [How It Works](01-how-it-works.md) | Start here: **which runbook to use**, what's changing, and the concepts behind it |
| 2. [Migrate Existing Sharing](02-migrate-existing-sharing.md) | Runbook for partners that already share through EWS-era config: discovery, setup, cutover, cleanup |
| 3. [Set Up New Sharing](03-set-up-new-sharing.md) | Runbook for partners that don't share yet: setup on each side, validation |
| [Enable-XtapPartner.ps1](Enable-XtapPartner.ps1) | Turns on M365 Collaboration trust and grants capabilities (Layers 2 and 3) for one partner. Used by both runbooks. Never changes Layer 1, which is done in the portal. |
| [Test-XtapPartner.ps1](Test-XtapPartner.ps1) | Read-only PASS/WARN/FAIL check of one partner, or every partner, in a tenant, with optional CSV. Doesn't check old EWS-era config. |

The manual PowerShell snippets in the runbooks' appendices mirror the scripts; if you change one, update the other. Diagrams (SVG) and screenshots (PNG) are in `images/`.
