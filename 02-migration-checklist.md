# Cross-Tenant Calendar Sharing Migration Checklist (EWS → M365 XTAP)

Last updated: September 28, 2026. If you haven't read it yet, start with [How It Works](01-how-it-works.md) for the concepts and diagrams behind these steps.

## Overview

Microsoft is retiring Exchange Web Services (EWS) in Exchange Online: soft block starting **October 1, 2026**, hard shutdown **April 1, 2027**. Cross-tenant Free/Busy, MailTips, and Calendar Sharing currently ride on EWS via Organization Relationships, Sharing Policies, or Availability Address Spaces. The replacement is **Microsoft 365 Cross-Tenant Access Policy (M365 XTAP)**, which has three layers:

| Layer | What it controls | Where it's configured |
| --- | --- | --- |
| 1. Entra Cross-Tenant Access Policy | B2B trust: MFA/device trust, invitation redemption, cross-tenant sync | Entra admin center → External Identities → Cross-tenant access settings (the existing grid, not where Free/Busy lives) |
| 2. M365 Collaboration trust | A per-partner inbound trust flag (`m365CollaborationInbound`) that must be on before Layer 3 does anything | Microsoft Graph (beta); no portal UI yet |
| 3. M365 capabilities | The actual grants: Free/Busy (basic/detail), MailTips, Calendar Sharing (simple/detail/reviewer), plus anonymous variants | Microsoft Graph (beta); no portal UI yet |

**What "inbound" means in this checklist.** Every XTAP setting is configured on one tenant and names one partner tenant. *Inbound* means requests from the partner's users coming *into* the tenant you're configuring. Granting an inbound capability lets the partner's users see this tenant's data. So on Op-Co A's tenant, an inbound Free/Busy grant for Op-Co B lets B's users see A's free/busy.

For each pair of operating companies that shares calendars/free-busy, both tenants must configure Layers 2 and 3 pointing at each other. This is bidirectional and can be asymmetric: each side decides what the other side may see of it, and the two sides don't have to grant the same level.

**How the work repeats.** For each op-co tenant: sign in once (Step 2), then run Steps 3 and 4 once for *each* partner that tenant shares with. Then switch to the next op-co tenant and repeat. A pairing is complete only when both tenants have run Steps 3 and 4 for each other.

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

# Which mailboxes use which Sharing Policy (a blank name means the Default policy)
Get-Mailbox -ResultSize Unlimited | Group-Object SharingPolicy | Select-Object Count, Name

# Availability Address Spaces (legacy free/busy trust, often cross-forest/hybrid-adjacent)
Get-AvailabilityAddressSpace | Format-List
```

A partner relationship is in scope for this migration if the partner org is hosted in Microsoft 365 and **any** of the following is true:

- **Organization Relationship**: `Enabled: True` with `FreeBusyAccessEnabled: True` and/or `MailTipsAccessEnabled: True` for the partner's domains.
- **Sharing Policy**: `Enabled: True`, a `Domains` rule for the partner's domain with a `CalendarSharingFreeBusy` access level (Simple, Detail, or Reviewer), and the policy is assigned to one or more mailboxes (per the `Get-Mailbox` grouping above).
- **Availability Address Space**: an entry whose `ForestName` is the partner's domain.

`Anonymous:`-prefixed Sharing Policy rules are calendar publishing to the public internet, not tenant-to-tenant sharing; call those out separately.

Record, per op-co: which partner op-cos it currently shares with, through which mechanism, and at what level (availability-only vs. full detail vs. calendar publish). This is the baseline you'll validate against in Step 5.

## Step 2: Prerequisites and sign-in

Check these before running anything:

- **Role required**: Security Administrator or Global Administrator in each tenant (Cross-Tenant Access Policy is a sensitive Entra permission).
- **Partner tenant IDs**: collect the Entra Tenant ID for every op-co that will be part of a sharing pair. Each op-co admin can find their own in Entra admin center → Overview → Tenant ID. Add these to the [pairings table](#per-pairing-tracking) before starting Layer 2/3 work, since every pairing needs the *other* tenant's ID.
- **Layer 1 is done in the portal**: each partner op-co should already appear under Entra ID → External Identities → Cross-tenant access settings → Organizational settings. Step 3 walks through verifying it (and adding it in the portal if missing). Layers 2/3 are configured against that same partner tenant ID.
- **No domain federation involved: this is a deliberate change from EWS.** The old EWS-based Free/Busy setup relied on domain-based federation (Microsoft Federation Gateway), which sometimes required a partner's `*.onmicrosoft.com` default domain to be present in the trust chain even after mailboxes were fully online. XTAP has no equivalent: every partner relationship (Layer 1 B2B and Layer 2/3 M365 Collaboration) is keyed purely on the partner's **Entra Tenant ID (GUID)**; there's no `DomainNames` parameter anywhere in the XTAP object model. Don't chase down onmicrosoft.com domains for this migration; the Tenant ID is the only identifier needed per op-co.

> **Shortcut:** [Enable-XtapPartner.ps1](Enable-XtapPartner.ps1) runs the sign-in plus the PowerShell parts of Steps 3 and 4 in one go, once per capability. You still verify Layer 1 in the portal first (Step 3). Try it first with `-WhatIf`. The manual steps below show what it does.

How the sign-in works:

- **You sign in with your own admin account: no app registration, certificate, or service principal.** This uses delegated auth via OAuth2 device-code flow against Microsoft's first-party "Microsoft Graph Command Line Tools" public client, which is pre-registered in every tenant, so there is nothing to create or configure ahead of time.
- **Entirely cloud-based, run from wherever you execute PowerShell.** No server, no on-prem footprint, no persistent credential to manage. Each session needs an interactive browser sign-in (the device-code flow gives you a URL and a one-time code to enter); the token that comes back is short-lived (roughly 60 to 90 minutes) and tied to you, not to a standing app identity.
- **Run this once per op-co tenant**, setting `$tenantId` to the tenant you're configuring. The token only works against that tenant.

```powershell
# Delegated auth via device-code flow: signs in as YOU, no app
# registration, certificate, or secret required.
$tenantId = "<your-tenant-id>"  # the op-co tenant you are configuring right now
$clientId = "14d82eec-204b-4c2f-b7e8-296a70dab67e"  # Microsoft Graph Command Line Tools (Microsoft first-party public client)
$scope    = "https://graph.microsoft.com/Policy.ReadWrite.CrossTenantAccess https://graph.microsoft.com/Policy.ReadWrite.CrossTenantCapability"

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

The first time you run this in a tenant, you'll be asked to consent to two **delegated** permissions; accept them once per tenant. `Policy.ReadWrite.CrossTenantAccess` covers the partner trust settings (Step 3). `Policy.ReadWrite.CrossTenantCapability` covers the `m365Capabilities` grants (Step 4); without it, the Step 4 call is rejected even for a Global Administrator. Consent only approves this application acting with your existing admin role; it doesn't grant you any new rights.

## Step 3: Verify Layer 1 in the portal, then enable M365 Collaboration trust (Layer 2)

Run once per partner tenant, from the tenant you signed in to in Step 2.

**Layer 1 (Entra admin center, no PowerShell).** Cross-tenant access settings are managed in the portal. For op-cos these entries almost always exist already, so this is a check:

1. Go to **Entra admin center → Entra ID → External Identities → Cross-tenant access settings → Organizational settings** and find the partner by name or Tenant ID. If it's missing, select **Add organization** and enter the partner's Tenant ID; the new entry inherits your default settings.
2. Open the partner's **Inbound access → Trust settings** and confirm it matches the environment standard: *Trust multifactor authentication from Microsoft Entra tenants* on; compliant and hybrid-joined device trust off. Fix it there if not.

Trust settings govern B2B guest sign-ins, not calendar sharing, so they aren't a prerequisite for Free/Busy. Checking them now just confirms the entry you're building on is correct.

**Layer 2 (PowerShell).** Turn on inbound M365 Collaboration trust before granting any capability; capability grants in Step 4 do nothing without it. There's no portal UI for this yet. This call only adds the M365 Collaboration setting and doesn't change the Layer 1 settings you just verified:

```powershell
$partnerTenantId = "<partner-tenant-id>"  # the partner op-co this tenant is trusting; also used in Step 4
$partnerUri      = "https://graph.microsoft.com/beta/policies/crossTenantAccessPolicy/partners/$partnerTenantId"

# M365 Collaboration trust for all users. Narrower scoping is done per capability in Step 4.
$body = @{
    m365CollaborationInbound = @{
        users = @{
            accessType = "allowed"
            targets    = @(@{ target = "AllUsers"; targetType = "user" })
        }
    }
} | ConvertTo-Json -Depth 6

Invoke-RestMethod -Method Patch -Uri $partnerUri `
    -Headers $headers -ContentType "application/json" -Body $body
```

If this returns 404, the partner entry doesn't exist; add the organization in the portal (above) and rerun. The `m365CollaborationInbound` property is taken from the [Microsoft Learn migration guide](https://learn.microsoft.com/en-us/exchange/sharing/migrate-to-m365-xtap); check it there before running against a production tenant, since the beta API is still changing.

## Step 4: Grant M365 capabilities (Layer 3)

Once Layer 2 trust is on for a partner, grant the capabilities that partner's users should have **inbound**, meaning what they may see of *this* tenant. Uses the same `$partnerTenantId` as Step 3. Example, Free/Busy only:

```powershell
# Grant an inbound M365 capability to a specific partner tenant
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

**Both sides must run this.** The call only affects the tenant it's run against. For Op-Co A and Op-Co B to see each other's free/busy, run it on A's tenant with B as the partner, and on B's tenant with A as the partner. Match the capability level (`Basic`/`Detail`, `Simple`/`Detail`/`Reviewer`) to what Step 1's discovery showed was in use, unless the business wants to change the sharing level as part of this migration.

## Step 5: Validation

Before touching the old EWS-based config, confirm the new path actually works:

- **Free/Busy**: in Outlook (desktop or OWA), have a user in Op-Co A create a meeting and add a user from Op-Co B as an attendee. Scheduling Assistant should show B's availability at the level B's tenant granted (free/busy only, or with subject/location if Detail was granted). Then repeat in the other direction.
- **MailTips**: if MailTips capability was granted, check that out-of-office / automatic-reply MailTips surface correctly when addressing a user in the partner org.
- **Calendar Sharing** (if granted beyond free/busy): have a user share their calendar with a specific partner-org user and confirm the recipient can open it.
- **Timing**: changes aren't always instant. If a test fails right after the Graph grant, wait and retry before troubleshooting, and note how long it took so later pairings have a realistic expectation.
- **Cross-check against Step 1's baseline**: confirm the new path matches or exceeds what the old configuration provided, so nothing regresses for end users during cutover.

Don't disable the old configuration until this validation passes for a given pairing; keep both live in parallel during testing.

## Step 6: Decommission old EWS-based config

Once validation passes for a given pairing and both sides are confirmed on the new path, remove the old config for that partner on each tenant. Save the Step 1 discovery output first so you can restore anything you remove.

```powershell
# Organization Relationship: disable (don't delete right away; keep for rollback)
Set-OrganizationRelationship -Identity "<PartnerOrgRelationship>" -Enabled $false

# Sharing Policy: remove only the partner's domain rule, NOT the whole policy.
# Disabling the policy would also break every other sharing rule for the mailboxes
# assigned to it (including all mailboxes on the Default policy).
# Copy the exact rule string from Get-SharingPolicy's Domains output.
Set-SharingPolicy -Identity "<SharingPolicyName>" -Domains @{Remove = "<partner-domain>:<AccessLevel>"}

# Availability Address Space: there is no disable switch, so removal is the only option.
# Keep the Step 1 Get-AvailabilityAddressSpace output so it can be recreated if needed.
Remove-AvailabilityAddressSpace -Identity "<partner-domain>"
```

- Disable rather than remove Organization Relationships initially; remove them outright only after a burn-in period (e.g., 2 to 4 weeks) with no reported issues.
- Do this per pairing as each is validated; don't wait to decommission everything at once, since EWS itself starts being blocked October 1, 2026 regardless.
- Track decommission status per pairing in the tables below so nothing gets missed before the hard EWS cutoff.

## Per-pairing tracking

Add one row per op-co pairing identified in Step 1's discovery, using the same pairing number in both tables.

**Pairings:**

| # | Op-Co A | A tenant ID | Op-Co B | B tenant ID | Level (F/B, MailTips, Calendar) |
| --- | --- | --- | --- | --- | --- |
| 1 |  |  |  |  |  |
| 2 |  |  |  |  |  |

**Status:** "On A" means configured on A's tenant with B as the partner, which lets B's users see A's data (and vice versa for "On B").

| # | Layer 2 on A | Layer 2 on B | Layer 3 on A | Layer 3 on B | Validated | Old config decommissioned |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | ☐ | ☐ | ☐ | ☐ | ☐ | ☐ |
| 2 | ☐ | ☐ | ☐ | ☐ | ☐ | ☐ |

## Key dates and references

- **October 1, 2026**: EWS soft block begins in Exchange Online (gradual rollout); cross-tenant Free/Busy, MailTips, and Calendar Sharing on the old EWS path start breaking as the block reaches each tenant.
- **April 1, 2027**: EWS hard shutdown; no exceptions past this date, including tenants that requested a temporary extension.
- [Retirement of Exchange Web Services in Exchange Online](https://techcommunity.microsoft.com/blog/exchange/retirement-of-exchange-web-services-in-exchange-online/3924440): Microsoft's original EWS retirement announcement (Exchange Team Blog / Microsoft Community Hub).
- [Cross-tenant Free/Busy, MailTips, and Calendar Sharing are moving to Cross-Tenant Access Policy](https://techcommunity.microsoft.com/blog/exchange/cross-tenant-freebusy-mailtips-and-calendar-sharing-are-moving-to-cross-tenant-a/4545169): the Exchange Team's detailed walkthrough behind Message Center notice MC1446796, including the rollout schedule and `Get-OrganizationRelationship` / `Get-SharingPolicy` discovery commands.
- **Message Center notice MC1446796**: "Migrate Free/Busy, MailTips, and Calendar Sharing before EWS deprecation" (visible in the Microsoft 365 admin center under Message Center; last updated August 25, 2026).
- [Migrate to Microsoft 365 Cross-Tenant Access Policy for sharing Free/Busy, Calendars, and MailTips](https://learn.microsoft.com/en-us/exchange/sharing/migrate-to-m365-xtap): Microsoft Learn, the authoritative step-by-step migration guide and source of truth for current Graph API syntax as the beta surface evolves.
- [Cross-tenant access settings (Microsoft Entra External ID)](https://learn.microsoft.com/en-us/entra/external-id/cross-tenant-access-settings-b2b-collaboration): Microsoft Learn reference for the Layer 1 B2B trust settings.
- [Help us shape Exchange Server on-premises to different online org Free/Busy after EWS retirement](https://techcommunity.microsoft.com/blog/exchange/help-us-shape-exchange-server-on-premises-to-different-online-org-freebusy-after/4549691): relevant only if any op-co is running Exchange hybrid rather than pure Exchange Online.
