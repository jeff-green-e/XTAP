# Cross-Tenant Calendar Sharing: EWS to M365 XTAP

Moving cross-tenant Free/Busy, MailTips, and Calendar Sharing between operating-company tenants off Exchange Web Services (EWS) and onto Microsoft 365 Cross-Tenant Access Policy ahead of the EWS retirement (soft block October 1, 2026; hard shutdown April 1, 2027).

| Doc | Purpose |
| --- | --- |
| 1. [How It Works](01-how-it-works.md) | Start here. Concepts and diagrams: what's changing, the three layers, inbound-per-tenant model, old-to-new setting map |
| 2. [Migration Checklist](02-migration-checklist.md) | Runbook: discovery, prerequisites, Graph REST calls in PowerShell, validation, decommission, per-pairing tracking |

Diagrams are standalone SVG files in `images/` and render in both GitHub and Azure DevOps.
