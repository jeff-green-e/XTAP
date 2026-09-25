# Cross-Tenant Calendar Sharing Migration Checklist (EWS → M365 XTAP)

Last updated: September 25, 2026. If you haven't read it yet, start with [How It Works](01-how-it-works.md) for the concepts and diagrams behind these steps.

## Overview

Microsoft is retiring Exchange Web Services (EWS) in Exchange Online: soft block starting **October 1, 2026**, hard shutdown **April 1, 2027**. Cross-tenant Free/Busy, MailTips, and Calendar Sharing currently ride on EWS via Organization Relationships, Sharing Policies, or Availability Address Spaces. The replacement is **Microsoft 365 Cross-Tenant Access Policy (M365 XTAP)**, which has three layers:

| Layer | What it controls | Where it's configured |
| --- | --- | --- |
| 1. Entra Cross-Tenant Access Policy | B2B trust: MFA/device trust, invitation redemption, cross-tenant sync | Entra admin center → External Identities → Cross-tenant access settings (the existing grid, not where Free/Busy lives) |
| 2. M365 Collaboration trust | A per-partner inbound trust flag (`m365CollaborationInbound`) that must be on before Layer 3 does anything | Microsoft Graph (beta); no portal UI yet |
| 3. M365 capabilities | The actual grants: Free/Busy (basic/detail), MailTips, Calendar Sharing (simple/detail/reviewer), plus anonymous variants | Microsoft Graph (beta); no portal UI yet |

For each pair of operating companies that shares calendars/free-busy, both tenants must configure Layers 2 and 3 pointing at each other; this is bidirectional and asymmetric (each side grants what it shares outward).

## Step 1: Discovery

Run against each operating-company tenant's Exchange Online PowerShell to find what's currently in scope.

**Prerequisites:**

- **ExchangeOnlineManagement module** (v3.x+), not the legacy Basic Auth remote PowerShell session:

```powershell
Install-Module -Name ExchangeOnlineManagement -Scope CurrentUser
```

- **Role required**: View-Only Organization Management (read-only, sufficient for discovery) or Organization Management, in each op-co tenant.
- **Connect per tenant**: run this once per op-co before its discovery commands, since Organization Relationships/Sharing Policies are tenant-scoped and there's no cross-tenant query:

```powershell
Connect-ExchangeOnline -UserPrincipalName admin@<opco-domain>.com
```

Then the discovery commands:

```powershell
# Organization Relationships (Free/Busy, MailTips)
Get-OrganizationRelationship | Format-List Name, DomainNames, Enabled, FreeBusyAccessEnabled, FreeBusyAccessLevel, FreeBusyAccessScope, MailTipsAccessEnabled, MailTipsAccessLevel, MailTipsAccessScope

# Sharing Policies (calendar sharing, incl. anonymous publishing)
Get-SharingPolicy | Format-List Name, Domains, Enabled, Default

# Availability Address Spaces (legacy free/busy trust, often cross-forest/hybrid-adjacent)
Get-AvailabilityAddressSpace | Format-List
```

A tenant is in scope for this migration if `Get-SharingPolicy` shows `Enabled: True`, a `Domains` rule with a `CalendarSharingFreeBusy` access level (Simple, Detail, or Reviewer), the external org is hosted in Microsoft 365, and the policy is assigned to one or more mailboxes. Note: `Anonymous:`-prefixed rules are calendar publishing to the public internet, not tenant-to-tenant sharing; call those out separately.

Record, per op-co: which partner op-cos it currently shares with, and at what level (availability-only vs. full detail vs. calendar publish).

## Step 2: Prerequisites

- **Sign in with your own Global Admin identity: no app registration, certificate, or service principal.** This uses delegated auth via OAuth2 device-code flow against Microsoft's first-party "Microsoft Graph Command Line Tools" public client, which is pre-registered in every tenant, so there is nothing to create or configure ahead of time.
- **Entirely cloud-based, run from wherever you execute PowerShell.** No server, no on-prem footprint, no persistent credential to manage. Each session needs an interactive browser sign-in (the device-code flow gives you a URL and a one-time code to enter); the token that comes back is short-lived (roughly 60 to 90 minutes) and tied to you, not to a standing app identity.

```powershell
# Delegated auth via device-code flow: signs in as YOU (Global Admin), no app
# registration, certificate, or secret required.
$tenantId = "<your-tenant-id>"
$clientId = "14d82eec-204b-4c2f-b7e8-296a70dab67e"  # Microsoft Graph Command Line Tools (Microsoft first-party public client)
$scope    = "https://graph.microsoft.com/Policy.ReadWrite.CrossTenantAccess"

$deviceCodeResponse = Invoke-RestMethod -Method Post `
    -Uri "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/devicecode" `
    -Body @{ client_id = $clientId; scope = $scope }

Write-Host $deviceCodeResponse.message
# "To sign in, use a web browser to open https://microsoft.com/devicelogin
#  and enter the code XXXXXXXXX." Do that now, signing in as an account
#  with Global Administrator or Security Administrator in this tenant.

do {
    Start-Sleep -Seconds $deviceCodeResponse.interval
    try {
        $token = Invoke-RestMethod -Method Post `
            -Uri "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token" `
            -Body @{
                grant_type  = "urn:ietf:params:oauth:grant-type:device_code"
                client_id   = $clientId
                device_code = $deviceCodeResponse.device_code
            }
        break
    } catch {
        # authorization_pending: keep polling until you finish signing in
    }
} while ($true)

$headers = @{ Authorization = "Bearer $($token.access_token)" }
# Reuse $headers on every call in Steps 3 and 4
```

The first time you run this in a given tenant, the sign-in prompt will ask you to consent to the `Policy.ReadWrite.CrossTenantAccess` **delegated** permission for your account; accept it once per tenant. No separate permission grant is needed beyond your existing Global Administrator or Security Administrator role; the consent prompt is just Entra confirming you want *this* application (Microsoft Graph Command Line Tools) to use that permission on your behalf.

- **Role required**: Security Administrator or Global Administrator in each tenant (Cross-Tenant Access Policy is a sensitive Entra permission).
- **Partner tenant IDs**: collect the Entra Tenant ID for every op-co that will be part of a sharing pair. Each op-co admin can find their own in Entra admin center → Overview → Tenant ID. Add these to the tracking table below before starting Layer 2/3 work, since every pairing needs the *other* tenant's ID.
- **No domain federation involved: this is a deliberate change from EWS.** The old EWS-based Free/Busy setup relied on domain-based federation (Microsoft Federation Gateway), which sometimes required a partner's `*.onmicrosoft.com` default domain to be present in the trust chain even after mailboxes were fully online. XTAP has no equivalent: every partner relationship (Layer 1 B2B and Layer 2/3 M365 Collaboration) is keyed purely on the partner's **Entra Tenant ID (GUID)**; there's no `DomainNames` parameter anywhere in the XTAP object model. Don't chase down onmicrosoft.com domains for this migration; the Tenant ID is the only identifier needed per op-co.
- **Confirm Layer 1 already exists**: the op-cos already show up as configured organizations under Entra ID → External Identities → Cross-tenant access settings → Organizational settings. Layers 2/3 are configured *against* that same partner tenant ID; no separate B2B setup is needed if it's already there, but if a pairing is missing from that list entirely, it'll need standard B2B org settings first.

## Step 3: Enable M365 Collaboration trust (Layer 2)

For each partner tenant, turn on the inbound M365 Collaboration trust level before granting any capability; capability grants in Step 4 do nothing without this. There's no portal exposure yet for this step; it's a REST call against the partner's tenant ID:

```powershell
# Enable M365 Collaboration inbound trust for a specific partner tenant
# Only MFA is trusted in this scenario; device compliance and hybrid Entra join are
# NOT accepted as substitutes, so both are explicitly false rather than omitted.
$body = @{
    inboundTrust = @{
        isMfaAccepted                       = $true
        isCompliantDeviceAccepted           = $false
        isHybridAzureADJoinedDeviceAccepted = $false
    }
} | ConvertTo-Json -Depth 6

Invoke-RestMethod -Method Patch `
    -Uri "https://graph.microsoft.com/beta/policies/crossTenantAccessPolicy/partners/$partnerTenantId" `
    -Headers $headers -ContentType "application/json" -Body $body
# Note: the exact property that flips on "m365CollaborationInbound" specifically is still
# moving on the beta surface; confirm the current field name against Microsoft Learn's
# migration doc before running this against a production tenant.
```

## Step 4: Grant M365 capabilities (Layer 3)

Once Layer 2 trust is on for a partner, grant the specific capabilities that partner should receive **inbound** (i.e., what the *other* tenant's users can see of *this* tenant). Example, Free/Busy only:

```powershell
# Grant an inbound M365 capability from a specific partner tenant
# Example: availability-only free/busy (crossTenantCalendarAvailabilityBasic)
# Other capability values: crossTenantCalendarAvailabilityDetail (time+subject+location),
#   crossTenantMailTipsBasic / crossTenantMailTipsDetail,
#   crossTenantCalendarSharingFreeBusySimple / ...Detail / ...Reviewer

$body = @{
    "@odata.type"  = "microsoft.graph.crossTenantCalendarAvailabilityBasic"
    inboundAccess  = @{
        isAllowed      = $true
        resourceScopes = @{
            included = @(@{ resourceId = "All"; resourceType = "user" })
            excluded = @()
        }
    }
} | ConvertTo-Json -Depth 6

Invoke-RestMethod -Method Post `
    -Uri "https://graph.microsoft.com/beta/policies/crossTenantAccessPolicy/partners/$partnerTenantId/m365Capabilities" `
    -Headers $headers -ContentType "application/json" -Body $body
```

**Bidirectional, asymmetric**: this call only grants what flows *inbound* into the tenant it's run against. For Op-Co A and Op-Co B to see each other's free/busy, this must run twice: once on A's tenant granting inbound access to B, once on B's tenant granting inbound access to A. Match the capability level (`Basic`/`Detail`, `Simple`/`Detail`/`Reviewer`) to what Step 1's discovery showed was in use under the old Organization Relationship, unless the business wants to change the sharing level as part of this migration.

## Step 5: Validation

Before touching the old EWS-based config, confirm the new path actually works:

- **Free/Busy**: in Outlook (desktop or OWA), have a user in Op-Co A create a meeting and add a user from Op-Co B as an attendee. Scheduling Assistant should show B's availability at the granted level (free/busy only, or with subject/location if Detail was granted).
- **MailTips**: check that out-of-office / automatic-reply MailTips surface correctly when addressing a user in the partner org, if MailTips capability was granted.
- **Calendar Sharing** (if granted beyond free/busy): have a user share their calendar with a specific partner-org user and confirm the recipient can open it.
- **Timing**: allow a short propagation delay after the Graph capability grant before testing; this is not always instant.
- **Cross-check against Step 1's baseline**: confirm the new path matches or exceeds what the old Organization Relationship provided, so nothing regresses for end users during cutover.

Don't disable the old Organization Relationship until this validation passes for a given pairing; keep both live in parallel during test.

## Step 6: Decommission old EWS-based config

Once validation passes for a given pairing and both sides are confirmed on the new path:

```powershell
# Disable (don't delete right away; keep for rollback until confident)
Set-OrganizationRelationship -Identity "<PartnerOrgRelationship>" -Enabled $false
Set-SharingPolicy -Identity "<PartnerSharingPolicy>" -Enabled $false
```

- Disable rather than remove initially; remove outright only after a burn-in period (e.g., 2 to 4 weeks) with no reported issues.
- Do this per pairing as each is validated; don't wait to decommission everything at once, since EWS itself starts being blocked October 1, 2026 regardless.
- Track decommission status per pairing in the table below so nothing gets missed before the hard EWS cutoff.

## Per-pairing tracking

| Op-Co A | Op-Co B | A tenant ID | B tenant ID | Level (F/B, MailTips, Calendar) | Layer 2 (A→B) | Layer 2 (B→A) | Layer 3 (A→B) | Layer 3 (B→A) | Validated | Old config decommissioned |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
|  |  |  |  |  | ☐ | ☐ | ☐ | ☐ | ☐ | ☐ |
|  |  |  |  |  | ☐ | ☐ | ☐ | ☐ | ☐ | ☐ |

Add one row per op-co pairing identified in Step 1's discovery. "A→B" means the capability granted on A's tenant that lets B's users see A's data (and vice versa).

## Key dates and references

- **October 1, 2026**: EWS soft block begins in Exchange Online (gradual rollout); cross-tenant Free/Busy, MailTips, and Calendar Sharing on the old EWS path start breaking as the block reaches each tenant.
- **April 1, 2027**: EWS hard shutdown; no exceptions past this date, including tenants that requested a temporary extension.
- [Retirement of Exchange Web Services in Exchange Online](https://techcommunity.microsoft.com/blog/exchange/retirement-of-exchange-web-services-in-exchange-online/3924440): Microsoft's original EWS retirement announcement (Exchange Team Blog / Microsoft Community Hub).
- [Cross-tenant Free/Busy, MailTips, and Calendar Sharing are moving to Cross-Tenant Access Policy](https://techcommunity.microsoft.com/blog/exchange/cross-tenant-freebusy-mailtips-and-calendar-sharing-are-moving-to-cross-tenant-a/4545169): the Exchange Team's detailed walkthrough behind Message Center notice MC1446796, including the rollout schedule and `Get-OrganizationRelationship` / `Get-SharingPolicy` discovery commands.
- **Message Center notice MC1446796**: "Migrate Free/Busy, MailTips, and Calendar Sharing before EWS deprecation" (visible in the Microsoft 365 admin center under Message Center; last updated August 25, 2026).
- [Migrate to Microsoft 365 Cross-Tenant Access Policy for sharing Free/Busy, Calendars, and MailTips](https://learn.microsoft.com/en-us/exchange/sharing/migrate-to-m365-xtap): Microsoft Learn, the authoritative step-by-step migration guide and source of truth for current Graph API syntax as the beta surface evolves.
- [Cross-tenant access settings (Microsoft Entra External ID)](https://learn.microsoft.com/en-us/entra/external-id/cross-tenant-access-settings-b2b-collaboration): Microsoft Learn reference for the Layer 1 B2B trust settings.
- [Help us shape Exchange Server on-premises to different online org Free/Busy after EWS retirement](https://techcommunity.microsoft.com/blog/exchange/help-us-shape-exchange-server-on-premises-to-different-online-org-freebusy-after/4549691): relevant only if any op-co is running Exchange hybrid rather than pure Exchange Online.
