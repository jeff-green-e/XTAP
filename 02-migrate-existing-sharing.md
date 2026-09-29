# Runbook: Migrate Existing Sharing (EWS → M365 XTAP)

Last updated: September 29, 2026. If you haven't read it yet, start with [How It Works](01-how-it-works.md) for the concepts and diagrams behind these steps.

**Use this runbook when** a tenant already shares Free/Busy, MailTips, or calendars with the partner through an Organization Relationship, Sharing Policy rule, or Availability Address Space. If neither tenant has any of those for the other, use [Set Up New Sharing](03-set-up-new-sharing.md) instead. Not sure? Step 1 below is read-only and tells you.

## Overview

Microsoft is retiring Exchange Web Services (EWS) in Exchange Online: soft block starting **October 1, 2026**, hard shutdown **April 1, 2027**. Cross-tenant Free/Busy, MailTips, and Calendar Sharing currently ride on EWS via Organization Relationships, Sharing Policies, or Availability Address Spaces. The replacement is **Microsoft 365 Cross-Tenant Access Policy (M365 XTAP)**, which has three layers:

| Layer | What it controls | Where it's configured |
| --- | --- | --- |
| 1. Entra Cross-Tenant Access Policy | B2B trust: MFA/device trust, invitation redemption, cross-tenant sync | Entra admin center → Identity → External Identities → Cross-tenant access settings (the existing grid, not where Free/Busy lives) |
| 2. M365 Collaboration trust | A per-partner inbound trust flag (`m365CollaborationInbound`) that must be on before Layer 3 does anything | Microsoft Graph (beta); no portal UI yet |
| 3. M365 capabilities | The actual grants: Free/Busy (basic/limited details), MailTips (limited/all), Calendar Sharing (simple/detail/reviewer), plus anonymous variants | Microsoft Graph (beta); no portal UI yet |

**What "inbound" means in this runbook.** Every XTAP setting is configured on one tenant and names one partner tenant. *Inbound* means requests from the partner's users coming *into* the tenant you're configuring. Granting an inbound capability lets the partner's users see this tenant's data. So on Op-Co A's tenant, an inbound Free/Busy grant for Op-Co B lets B's users see A's free/busy.

For each pair of operating companies that shares calendars/free-busy, both tenants must configure Layers 2 and 3 pointing at each other. This is bidirectional and can be asymmetric: each side decides what the other side may see of it, and the two sides don't have to grant the same level.

**How the work repeats.** Discovery (Step 1) runs once per op-co tenant. Steps 3 to 5 run once per *partner* in each tenant: check the partner in the portal, run the enable script, check the result. A pairing is ready to cut over (Step 6) only when *both* tenants have done Steps 3 to 5 for each other.

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
Get-OrganizationRelationship | Format-List Name, DomainNames, Enabled, FreeBusyAccessEnabled, FreeBusyAccessLevel, FreeBusyAccessScope, MailTipsAccessEnabled, MailTipsAccessLevel, MailTipsAccessScope, TargetSharingEpr, TargetAutodiscoverEpr

# Sharing Policies (calendar sharing, incl. anonymous publishing)
Get-SharingPolicy | Format-List Name, Domains, Enabled, Default

# Which mailboxes use which Sharing Policy (a blank name means the Default policy)
Get-Mailbox -ResultSize Unlimited | Group-Object SharingPolicy | Select-Object Count, Name

# Availability Address Spaces (org-wide free/busy trust)
Get-AvailabilityAddressSpace | Format-List ForestName, AccessMethod, TargetAutodiscoverEpr, TargetServiceEpr, TargetTenantId
```

A partner relationship is in scope for this migration if the partner org is hosted in Microsoft 365 and **any** of the following is true:

- **Organization Relationship**: `Enabled: True` with `FreeBusyAccessEnabled: True` and/or `MailTipsAccessEnabled: True` for the partner's domains. A `TargetSharingEpr` or `TargetAutodiscoverEpr` containing outlook.com, office365.com, or office365.us confirms the partner is in Microsoft 365. If the same relationship is also used for something else (for example cross-tenant mailbox migration), move that to a separate Organization Relationship before cutover.
- **Sharing Policy**: `Enabled: True`, a `Domains` rule for the partner's domain with a `CalendarSharingFreeBusy` access level (Simple, Detail, or Reviewer), and the policy is assigned to one or more mailboxes (per the `Get-Mailbox` grouping above).
- **Availability Address Space** (optional to migrate): an entry whose `ForestName` is the partner's domain and whose `AccessMethod` is `OrgWideFBToken`. These don't use EWS, so they keep working after the shutdown; migrate them to get XTAP's scoping and security features. Entries with any other `AccessMethod` can't be migrated to XTAP.

`Anonymous:`-prefixed Sharing Policy rules are calendar publishing to the public internet, not tenant-to-tenant sharing; call those out separately.

Record, per op-co: which partner op-cos it currently shares with, through which mechanism, and at what level (availability-only vs. full detail vs. calendar publish). This is the baseline you'll validate against in Step 6.

## Step 2: Prerequisites

Check these before changing anything:

- **Roles required** in each tenant:
  - Security Administrator or Global Administrator for the portal check (Step 3).
  - **Global Administrator** to run the enable script (Step 4), because it turns on M365 Collaboration trust. Microsoft's guide doesn't list any lesser role for that.
  - Global Reader or higher for the configuration check (Step 5).
  - Organization Management in Exchange Online to turn off and remove old configuration (Steps 6 and 7).
- **Partner tenant IDs**: collect the Entra Tenant ID for every op-co that will be part of a sharing pair. Each op-co admin can find their own in Entra admin center → Identity → Overview → Tenant ID. Add these to the [pairings table](#per-pairing-tracking) before starting, since every pairing needs the *other* tenant's ID.
- **The scripts**: download [Enable-XtapPartner.ps1](Enable-XtapPartner.ps1) and [Test-XtapPartner.ps1](Test-XtapPartner.ps1) from this repo into one folder. Downloaded scripts are usually blocked; [unblock them](#unblock-the-downloaded-scripts) before running. Use PowerShell 7 (Windows PowerShell 5.1 should also work) in a normal window opened in that folder; no modules to install. If the execution policy stops a script, `Set-ExecutionPolicy -Scope Process Bypass` allows it for that window only.
- **No domain federation involved: this is a deliberate change from EWS.** The old EWS-based Free/Busy setup relied on domain-based federation (Microsoft Federation Gateway), which sometimes required a partner's `*.onmicrosoft.com` default domain to be present in the trust chain even after mailboxes were fully online. XTAP has no equivalent: every partner relationship (Layer 1 B2B and Layer 2/3 M365 Collaboration) is keyed purely on the partner's **Entra Tenant ID (GUID)**; there's no `DomainNames` parameter anywhere in the XTAP object model. Don't chase down onmicrosoft.com domains for this migration; the Tenant ID is the only identifier needed per op-co.

### Unblock the downloaded scripts

Windows marks files downloaded through a browser as coming from the internet, and PowerShell won't run them until they're unblocked. A blocked script fails with an error like *"Enable-XtapPartner.ps1 cannot be loaded. The file … is not digitally signed. You cannot run this script on the current system."* Unblock both scripts once after downloading, either way:

- **File Explorer**: right-click the file → **Properties** → **General** tab → tick **Unblock** → **OK**. If there's no Unblock checkbox, the file isn't blocked.
- **PowerShell**, in the folder with the scripts:

  ```powershell
  Unblock-File -Path .\Enable-XtapPartner.ps1, .\Test-XtapPartner.ps1
  ```

![File Properties dialog for Enable-XtapPartner.ps1, with the Unblock checkbox ticked next to "This file came from another computer and might be blocked to help protect this computer"](images/04-unblock-script.png)

Files you get with `git clone` aren't marked, so they don't need unblocking.

## Step 3: Verify the partner organization in Entra admin center (Layer 1)

Run once per partner. Cross-tenant access settings are managed in the portal, not with PowerShell. For op-cos these entries almost always exist already, so this is a check:

1. Go to **Entra admin center → Identity → External Identities → Cross-tenant access settings → Organizational settings** and find the partner by name or Tenant ID. If it's missing, select **Add organization** and enter the partner's Tenant ID; the new entry inherits your default settings.
2. Open the partner's **Inbound access → Trust settings** and confirm it matches the environment standard: *Trust multifactor authentication from Microsoft Entra tenants* on; compliant and hybrid-joined device trust off. Fix it there if not.

Trust settings govern B2B guest sign-ins, not calendar sharing, so they aren't a prerequisite for Free/Busy. Checking them now just confirms the entry you're building on is correct.

## Step 4: Turn on sharing with Enable-XtapPartner.ps1 (Layers 2 and 3)

Run once per partner. [Enable-XtapPartner.ps1](Enable-XtapPartner.ps1) signs you in, turns on M365 Collaboration trust for the partner (Layer 2), and grants the capabilities you choose (Layer 3). It never changes the Layer 1 settings from Step 3, and it won't overwrite a Layer 2 setting someone has limited or blocked. There's no portal UI for Layers 2 and 3 yet.

### Choose capabilities

Match what Step 1 found. Names are case-sensitive.

| Old setting (from Step 1) | Capability |
| --- | --- |
| Organization Relationship `FreeBusyAccessLevel AvailabilityOnly`, or an `OrgWideFBToken` Availability Address Space | `crossTenantCalendarAvailabilityBasic` (the script's default) |
| Organization Relationship `FreeBusyAccessLevel LimitedDetails` | `crossTenantCalendarAvailabilityLimitedDetails` |
| Organization Relationship `MailTipsAccessLevel Limited` | `crossTenantMailTipsLimited` |
| Organization Relationship `MailTipsAccessLevel All` | `crossTenantMailTipsAll` |
| Sharing Policy `CalendarSharingFreeBusySimple` | `crossTenantCalendarSharingFreeBusySimple` |
| Sharing Policy `CalendarSharingFreeBusyDetail` | `crossTenantCalendarSharingFreeBusyDetail` |
| Sharing Policy `CalendarSharingFreeBusyReviewer` | `crossTenantCalendarSharingFreeBusyReviewer` |

Change the level only if the business wants to as part of this migration.

**Group-limited sharing:** if the old Organization Relationship used `FreeBusyAccessScope` or `MailTipsAccessScope` (a group), or different mailboxes were on different Sharing Policies, the grant needs to be limited to a security group. The script always grants to all users, so use the [manual steps](#appendix-manual-powershell-steps) for those capabilities.

### Dry run

Run with `-WhatIf` first. It signs in and reads the current settings, but changes nothing:

```powershell
.\Enable-XtapPartner.ps1 -TenantId <this-tenant-id> -PartnerTenantId <partner-tenant-id> -WhatIf
```

1. The script prints a URL and a code. Open the URL in a browser, enter the code, and sign in as a Global Administrator of **this** tenant (the one you're configuring).
2. The first time in a tenant, you're asked to consent to `Policy.ReadWrite.CrossTenantAccess` and `Policy.ReadWrite.CrossTenantCapability` for Microsoft Graph Command Line Tools. Accept. This only lets the tool act with the admin rights you already have.
3. Check the "What if" lines: one for turning on M365 Collaboration trust (unless it's already on) and one for each capability not yet granted.

### Run it

Run the same command without `-WhatIf`, adding `-Capability` if you need more than Free/Busy times:

```powershell
# Free/Busy times only (the default)
.\Enable-XtapPartner.ps1 -TenantId <this-tenant-id> -PartnerTenantId <partner-tenant-id>

# Example: Free/Busy with subject and location, plus all MailTips
.\Enable-XtapPartner.ps1 -TenantId <this-tenant-id> -PartnerTenantId <partner-tenant-id> `
    -Capability crossTenantCalendarAvailabilityLimitedDetails, crossTenantMailTipsAll
```

A successful run ends with a summary like this:

```text
Layer 2: M365 Collaboration trust turned on.
Layer 3: granted crossTenantCalendarAvailabilityBasic to partner (all users).

Partner <partner-tenant-id>, as configured in tenant <this-tenant-id>
  M365 Collaboration trust: allowed for all users
  Capability: crossTenantCalendarAvailabilityBasic: allowed for all users
```

"Already on" or "already configured, no change" lines are fine; that part was set up before. Running the script again is always safe. If it stops with an error, see the [error table in Set Up New Sharing](03-set-up-new-sharing.md#if-the-script-stops); the messages and fixes are the same.

**Both sides must do this.** The script only configures the tenant you sign in to. For Op-Co A and Op-Co B to see each other, A's admin runs it with B as the partner, and B's admin runs it with A as the partner.

## Step 5: Check both sides

Before cutting over, each admin runs the read-only check in their own tenant, with the other tenant as the partner and the capabilities they granted:

```powershell
.\Test-XtapPartner.ps1 -TenantId <this-tenant-id> -PartnerTenantId <partner-tenant-id> `
    -ExpectedCapability crossTenantCalendarAvailabilityBasic -CsvPath .\xtap-check.csv
```

It signs in the same way (Global Reader is enough). Expect **PASS** for Partner entry, Trust settings, M365 Collab trust, and each expected capability. A WARN on Trust settings means Step 3 doesn't match the standard; fix it in the portal, though it doesn't block calendar sharing. **Don't cut over until both sides have no FAIL results.** Keep the CSV for the change record.

## Step 6: Cut over and validate

**Old configuration takes precedence over XTAP.** While an Organization Relationship, Sharing Policy rule, or Availability Address Space for the partner is still active, Outlook uses it, so testing with both in place proves nothing about the new path. Cut over one pairing at a time: turn the old configuration off on **both** tenants, then test right away. Agree a time with the partner's admin so both sides switch together, since users lose cross-tenant free/busy between the switch and a successful test (or a rollback).

**1. Back up and turn off the old configuration, on both tenants:**

```powershell
# Organization Relationship: disable (keep it for rollback)
Set-OrganizationRelationship -Identity "<PartnerOrgRelationship>" -Enabled $false

# Sharing Policy: remove only the partner's domain rule, NOT the whole policy.
# Copy the exact rule string from Get-SharingPolicy's Domains output, and keep it for rollback.
Set-SharingPolicy -Identity "<SharingPolicyName>" -Domains @{Remove = "<partner-domain>:<AccessLevel>"}

# Availability Address Space (only if migrating it): there's no disable switch, so back it up, then remove it.
Get-AvailabilityAddressSpace "<partner-domain>" | Export-CliXML ".\AvailabilityAddressSpaceBackup_<partner-domain>.xml"
Remove-AvailabilityAddressSpace "<partner-domain>"
```

Microsoft's guide disables the whole Sharing Policy (`Set-SharingPolicy -Enabled $false`). This runbook removes just the partner's rule instead, because disabling a policy also breaks every other sharing rule for the mailboxes assigned to it, which includes every mailbox on the Default policy. Disable the whole policy only if it contains nothing but this partner's rule.

**2. Test, in both directions:**

- **Free/Busy**: in Outlook (desktop or web), have a user in Op-Co A create a meeting and add a user from Op-Co B as an attendee. Scheduling Assistant should show B's availability at the level B's tenant granted (times only, or with subject/location if Limited Details was granted). Then repeat from B to A.
- **MailTips** (if granted): address a partner user who has automatic replies on; the MailTip should appear before sending.
- **Calendar Sharing** (if granted): have a user share their calendar with a partner user and confirm the recipient can open it at the granted level.
- **Group scoping** (if used): confirm a user outside the group shows no availability to the partner.
- **Timing**: changes aren't always instant. If a test fails right after cutover, wait and retry before rolling back, and note how long it took so later pairings have a realistic expectation.
- **Compare with Step 1's baseline**: the new path should match or exceed what the old configuration provided.

**3. If it doesn't work, roll back** on the tenant that isn't showing data (the tenant being looked *at*), then troubleshoot before trying again:

```powershell
Set-OrganizationRelationship -Identity "<PartnerOrgRelationship>" -Enabled $true
Set-SharingPolicy -Identity "<SharingPolicyName>" -Domains @{Add = "<partner-domain>:<AccessLevel>"}

# Restore an Availability Address Space from its backup
Import-Clixml ".\AvailabilityAddressSpaceBackup_<partner-domain>.xml" | ForEach-Object {
    $p = @{ ForestName = $_.ForestName; AccessMethod = $_.AccessMethod }
    foreach ($n in 'ProxyUrl', 'TargetAutodiscoverEpr', 'TargetServiceEpr', 'TargetTenantId') {
        if (-not [string]::IsNullOrEmpty($_.$n)) { $p[$n] = $_.$n }
    }
    Add-AvailabilityAddressSpace @p
}
```

Do this per pairing as each is ready; don't wait to cut over everything at once, since EWS starts being blocked October 1, 2026 regardless.

## Step 7: Clean up old configuration

After a burn-in period with no reported issues (e.g., 2 to 4 weeks), remove what you turned off:

```powershell
Remove-OrganizationRelationship -Identity "<PartnerOrgRelationship>"

# Only if the policy is now unused (no rules left that anyone needs, and no mailboxes assigned)
Remove-SharingPolicy -Identity "<SharingPolicyName>"
```

Keep the Availability Address Space backup files until the burn-in is over, then delete them. Track cleanup per pairing in the tables below so nothing is left behind before the April 1, 2027 hard cutoff.

## Per-pairing tracking

Add one row per op-co pairing identified in Step 1's discovery, using the same pairing number in both tables.

**Pairings:**

| # | Op-Co A | A tenant ID | Op-Co B | B tenant ID | Level (F/B, MailTips, Calendar) |
| --- | --- | --- | --- | --- | --- |
| 1 |  |  |  |  |  |
| 2 |  |  |  |  |  |

**Status:** "Script run on A" means the enable script ran in A's tenant with B as the partner, which lets B's users see A's data (and vice versa for B).

| # | Portal checked on A and B (Step 3) | Script run on A (Step 4) | Script run on B (Step 4) | Both checks clean (Step 5) | Old config off on both (Step 6) | Validated (Step 6) | Old config removed (Step 7) |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | ☐ | ☐ | ☐ | ☐ | ☐ | ☐ | ☐ |
| 2 | ☐ | ☐ | ☐ | ☐ | ☐ | ☐ | ☐ |

## Appendix: Manual PowerShell steps

Use these instead of the Step 4 script only when you need something it doesn't do, such as limiting a grant to a security group, or when the script can't be run. They make the same Graph calls. [Set Up New Sharing](03-set-up-new-sharing.md#appendix-manual-powershell-steps) uses the same sign-in.

### Sign in

- **You sign in with your own admin account: no app registration, certificate, or service principal.** This uses delegated auth via OAuth2 device-code flow against Microsoft's first-party "Microsoft Graph Command Line Tools" public client, which is pre-registered in every tenant, so there is nothing to create or configure ahead of time.
- **The token only works against the tenant you sign in to** and is short-lived (roughly 60 to 90 minutes). Run everything below **in the same PowerShell window**: the sign-in sets `$headers`, which the later blocks use. If you close the window or the token expires, sign in again.

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
#  and enter the code XXXXXXXXX." Do that now, signing in as a
#  Global Administrator of this tenant.

$interval = [int]$deviceCodeResponse.interval
$deadline = (Get-Date).AddSeconds([int]$deviceCodeResponse.expires_in)
$token    = $null

while (-not $token) {
    if ((Get-Date) -gt $deadline) { throw "The sign-in code expired. Run this block again." }
    Start-Sleep -Seconds $interval
    try {
        $token = Invoke-RestMethod -Method Post `
            -Uri "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token" `
            -Body @{
                grant_type  = "urn:ietf:params:oauth:grant-type:device_code"
                client_id   = $clientId
                device_code = $deviceCodeResponse.device_code
            }
    } catch {
        $err  = $_
        $code = try { ($err.ErrorDetails.Message | ConvertFrom-Json).error } catch { $null }
        switch ($code) {
            'authorization_pending' { }                  # not signed in yet; keep waiting
            'slow_down'             { $interval += 5 }   # server asked us to poll less often
            default                 { throw $err }       # declined, expired, wrong tenant, etc.
        }
    }
}

$headers = @{ Authorization = "Bearer $($token.access_token)" }
# Reuse $headers on every call below
```

The first time in a tenant, you're asked to consent to two **delegated** permissions; accept them once per tenant. `Policy.ReadWrite.CrossTenantAccess` covers the M365 Collaboration trust; `Policy.ReadWrite.CrossTenantCapability` covers the capability grants, and without it they're rejected even for a Global Administrator. Consent only approves this application acting with your existing admin role; it doesn't grant you any new rights.

### Turn on M365 Collaboration trust (Layer 2)

**Before running it**, check that M365 Collaboration trust isn't already set for this partner. This PATCH replaces whatever is there, so a setting someone limited to specific users, or blocked, would silently become "all users". [Test-XtapPartner.ps1](Test-XtapPartner.ps1) shows the current value. If it's already set to anything other than all users, review it with whoever configured it first.

```powershell
$partnerTenantId = "<partner-tenant-id>"  # the partner op-co this tenant is trusting; also used below
$partnerUri      = "https://graph.microsoft.com/beta/policies/crossTenantAccessPolicy/partners/$partnerTenantId"

# M365 Collaboration trust for all users. Narrower scoping is done per capability below.
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

If this returns 404, the partner entry doesn't exist; add the organization in the portal (Step 3) and rerun. The `m365CollaborationInbound` property is taken from the [Microsoft Learn migration guide](https://learn.microsoft.com/en-us/exchange/sharing/migrate-to-m365-xtap); check it there before running against a production tenant, since the beta API is still changing.

### Grant a capability (Layer 3)

Run once per capability, using a name from the [Step 4 table](#choose-capabilities):

```powershell
$capability = "crossTenantCalendarAvailabilityBasic"

# Who in THIS tenant the partner can see. Use one of these:
$scope = @{ resourceId = "All"; resourceType = "user" }                 # all users (for Calendar Sharing capabilities, use resourceType = "group")
# $scope = @{ resourceId = "<group-object-id>"; resourceType = "group" }  # only members of a security group

$body = @{
    "@odata.type"  = "#microsoft.graph.$capability"
    inboundAccess  = @{
        isAllowed      = $true
        resourceScopes = @{
            included = @($scope)
            excluded = @()
        }
    }
} | ConvertTo-Json -Depth 6

Invoke-RestMethod -Method Post `
    -Uri "https://graph.microsoft.com/beta/policies/crossTenantAccessPolicy/partners/$partnerTenantId/m365Capabilities" `
    -Headers $headers -ContentType "application/json" -Body $body
```

Then continue with [Step 5](#step-5-check-both-sides).

## Key dates and references

- **October 1, 2026**: EWS soft block begins in Exchange Online (gradual rollout); cross-tenant Free/Busy, MailTips, and Calendar Sharing on the old EWS path start breaking as the block reaches each tenant.
- **April 1, 2027**: EWS hard shutdown; no exceptions past this date, including tenants that requested a temporary extension.
- [Retirement of Exchange Web Services in Exchange Online](https://techcommunity.microsoft.com/blog/exchange/retirement-of-exchange-web-services-in-exchange-online/3924440): Microsoft's original EWS retirement announcement (Exchange Team Blog / Microsoft Community Hub).
- [Cross-tenant Free/Busy, MailTips, and Calendar Sharing are moving to Cross-Tenant Access Policy](https://techcommunity.microsoft.com/blog/exchange/cross-tenant-freebusy-mailtips-and-calendar-sharing-are-moving-to-cross-tenant-a/4545169): the Exchange Team's detailed walkthrough behind Message Center notice MC1446796, including the rollout schedule and `Get-OrganizationRelationship` / `Get-SharingPolicy` discovery commands.
- **Message Center notice MC1446796**: "Migrate Free/Busy, MailTips, and Calendar Sharing before EWS deprecation" (visible in the Microsoft 365 admin center under Message Center; last updated August 25, 2026).
- [Migrate to Microsoft 365 Cross-Tenant Access Policy for sharing Free/Busy, Calendars, and MailTips](https://learn.microsoft.com/en-us/exchange/sharing/migrate-to-m365-xtap): Microsoft Learn, the authoritative step-by-step migration guide and source of truth for current Graph API syntax as the beta surface evolves.
- [Cross-tenant access settings (Microsoft Entra External ID)](https://learn.microsoft.com/en-us/entra/external-id/cross-tenant-access-settings-b2b-collaboration): Microsoft Learn reference for the Layer 1 B2B trust settings.
- [Help us shape Exchange Server on-premises to different online org Free/Busy after EWS retirement](https://techcommunity.microsoft.com/blog/exchange/help-us-shape-exchange-server-on-premises-to-different-online-org-freebusy-after/4549691): relevant only if any op-co is running Exchange hybrid rather than pure Exchange Online.
