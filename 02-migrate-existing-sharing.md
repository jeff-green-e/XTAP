# Runbook: Migrate Existing Sharing (EWS → M365 XTAP)

Last updated: September 29, 2026. New to this? Read [How It Works](01-how-it-works.md) first.

**Use this runbook when** either tenant already shares with the partner through an Organization Relationship, Sharing Policy rule, or Availability Address Space. Otherwise use [Set Up New Sharing](03-set-up-new-sharing.md). Not sure? Step 1 is read-only and tells you.

## Overview

EWS is being retired in Exchange Online: soft block from **October 1, 2026**, hard shutdown **April 1, 2027**. Cross-tenant Free/Busy, MailTips, and Calendar Sharing that ride on EWS move to **Microsoft 365 Cross-Tenant Access Policy (M365 XTAP)**. See [How It Works](01-how-it-works.md) for the three layers and what "inbound" means.

**How the work repeats.** Discovery (Step 1) runs once per op-co tenant. Steps 3 to 5 run once per *partner* in each tenant. A pairing is ready to cut over (Step 6) only when *both* tenants have done Steps 3 to 5 for each other.

## Step 1: Discovery

Run in each op-co tenant to find what's in scope.

**Prerequisites:**

- **ExchangeOnlineManagement module** (v3.x+):

```powershell
Install-Module -Name ExchangeOnlineManagement -Scope CurrentUser
```

- **Role**: View-Only Organization Management or Organization Management.
- **Connect to each tenant** before running its discovery commands:

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

A partner is in scope if it's hosted in Microsoft 365 and **any** of these is true:

- **Organization Relationship**: `Enabled: True` with `FreeBusyAccessEnabled` and/or `MailTipsAccessEnabled` true for the partner's domains. `TargetSharingEpr` or `TargetAutodiscoverEpr` containing outlook.com, office365.com, or office365.us means the partner is in Microsoft 365. If the relationship is also used for something else (such as mailbox migration), split that out before cutover.
- **Sharing Policy**: `Enabled: True`, a `Domains` rule for the partner's domain with a `CalendarSharingFreeBusy*` level, and assigned to at least one mailbox.
- **Availability Address Space** (optional): `ForestName` is the partner's domain and `AccessMethod` is `OrgWideFBToken`. These don't use EWS and keep working; migrate them for XTAP's scoping and security. Other `AccessMethod` values can't be migrated.

`Anonymous:` Sharing Policy rules are public calendar publishing, not tenant-to-tenant sharing; note them separately.

Record, per op-co, which partners it shares with, how, and at what level. You'll compare against this in Step 6.

## Step 2: Prerequisites

- **Roles** in each tenant:
  - Step 3 (portal): Security Administrator or Global Administrator.
  - Step 4 (enable script): **Global Administrator**.
  - Step 5 (check script): Global Administrator, or Global Reader once an admin has approved the tool.
  - Steps 6 and 7 (old config): Exchange Organization Management.
- **Tenant IDs** for every op-co in a pairing (Entra admin center → Identity → Overview → Tenant ID). Record them in the [pairings table](#per-pairing-tracking).
- **The scripts**: download [Enable-XtapPartner.ps1](Enable-XtapPartner.ps1) and [Test-XtapPartner.ps1](Test-XtapPartner.ps1) into one folder and [unblock them](#unblock-the-downloaded-scripts). Run them from PowerShell 7 (5.1 should also work) opened in that folder. If the execution policy blocks them, run `Set-ExecutionPolicy -Scope Process Bypass` (this window only).
- **Microsoft.Graph.Authentication** PowerShell module. Most admins already have it; the scripts check and tell you if it's missing (`Install-Module Microsoft.Graph.Authentication -Scope CurrentUser`).
- **No domains needed.** Unlike EWS federation, XTAP identifies partners only by **Tenant ID**. Don't chase down `onmicrosoft.com` domains.

### Unblock the downloaded scripts

Windows blocks scripts downloaded through a browser. A blocked script fails with *"…is not digitally signed. You cannot run this script on the current system."* Unblock both once, either way:

- **File Explorer**: right-click → **Properties** → tick **Unblock** → **OK**. No checkbox means it isn't blocked.
- **PowerShell**, in the folder with the scripts:

  ```powershell
  Unblock-File -Path .\Enable-XtapPartner.ps1, .\Test-XtapPartner.ps1
  ```

![File Properties dialog for Enable-XtapPartner.ps1, with the Unblock checkbox ticked next to "This file came from another computer and might be blocked to help protect this computer"](images/04-unblock-script.png)

Files from `git clone` don't need unblocking.

## Step 3: Confirm the partner organization exists in Entra admin center (Layer 1)

Run once per partner. For op-cos this entry almost always exists already.

Go to **Entra admin center → Identity → External Identities → Cross-tenant access settings → Organizational settings** and find the partner. If it's missing, select **Add organization** and enter its Tenant ID. Don't change its trust settings (MFA, device trust); they apply to B2B guest sign-ins, not calendar sharing.

## Step 4: Turn on sharing with Enable-XtapPartner.ps1 (Layers 2 and 3)

Run once per partner. There's no portal UI for Layers 2 and 3, so the script does them: it turns on M365 Collaboration trust and grants the capabilities you choose. It won't change Layer 1 or overwrite a Layer 2 setting someone has limited.

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

**Group-limited sharing** (the old relationship used `FreeBusyAccessScope`/`MailTipsAccessScope`, or mailboxes were on different Sharing Policies): the script always grants to all users, so use the [manual steps](#appendix-manual-powershell-steps).

### Run it

```powershell
# Free/Busy times only (the default)
.\Enable-XtapPartner.ps1 -TenantId <this-tenant-id> -PartnerTenantId <partner-tenant-id>

# Example: Free/Busy with subject and location, plus all MailTips
.\Enable-XtapPartner.ps1 -TenantId <this-tenant-id> -PartnerTenantId <partner-tenant-id> `
    -Capability crossTenantCalendarAvailabilityLimitedDetails, crossTenantMailTipsAll
```

1. **Sign in.** An account picker or browser window opens; choose a Global Administrator account for **this** tenant. If this PowerShell window is already signed in to that tenant (for example from an earlier run), the script reuses it and doesn't ask. No usable browser, such as in a remote session? Add `-UseDeviceCode` and follow the code prompt instead.
2. **Consent (first time per tenant).** Microsoft shows a **Permissions requested** prompt for Microsoft Graph Command Line Tools. The first two lines are what the script needs; the others are standard sign-in permissions. **Leave "Consent on behalf of your organization" unticked**, then select **Accept**.

   ![Permissions requested prompt for Microsoft Graph Command Line Tools, listing cross tenant access policies, M365 cross tenant access capabilities, basic profile, and maintain access, with the "Consent on behalf of your organization" checkbox unticked](images/05-consent-prompt.png)
3. **Confirm each change** back in PowerShell:

   ```text
   Confirm
   Are you sure you want to perform this action?
   Performing the operation "Turn on M365 Collaboration trust for all users" on target "partner <partner-tenant-id>".
   [Y] Yes  [A] Yes to All  [N] No  [L] No to All  [S] Suspend  [?] Help (default is "Y"):
   ```

   Check the partner ID, then type **Y** (or **A** for all). **N** skips that change. **Enter alone counts as Yes.** There's one prompt per change needed; none if everything is already set.

A successful run ends with a summary like this:

```text
Layer 2: M365 Collaboration trust turned on.
Layer 3: granted crossTenantCalendarAvailabilityBasic to partner (all users).

Partner <partner-tenant-id>, as configured in tenant <this-tenant-id>
  M365 Collaboration trust: allowed for all users
  Capability: crossTenantCalendarAvailabilityBasic: allowed for all users
```

"Already on" or "no change" lines are fine, and rerunning is always safe. `-WhatIf` previews without changing anything; `-Confirm:$false` skips the prompts. For errors, see [If the script stops](03-set-up-new-sharing.md#if-the-script-stops). When you're finished, especially on a shared machine, run `Disconnect-MgGraph` to sign out.

**Both sides must do this:** A's admin runs it with B as the partner, and B's admin with A.

## Step 5: Check your side, and confirm the partner's side

Each admin can only check their own tenant, so each checks their side and you compare results.

**1. Check your side** with the capabilities you granted in Step 4:

```powershell
.\Test-XtapPartner.ps1 -TenantId <this-tenant-id> -PartnerTenantId <partner-tenant-id> `
    -ExpectedCapability crossTenantCalendarAvailabilityBasic -CsvPath .\xtap-check.csv
```

| Check | Expected | If not |
| --- | --- | --- |
| Partner entry | PASS | Add the partner in the portal (Step 3), then rerun the enable script. |
| M365 Collab trust | PASS: "Allowed for all users." | "Not configured" or "inherited from default": rerun the enable script and answer **Y** to the M365 Collaboration trust prompt. Limited or blocked on this partner: the script won't change it; review it with whoever set it. |
| Expected capability | PASS for each one listed | Rerun the enable script with the missing capability in `-Capability`. |
| Capability | INFO lines listing what's granted | Nothing to do; this is for reference. |

If the same window is still signed in from the enable script, the check reuses that sign-in. Otherwise it asks for read-only permissions; leave **Consent on behalf of your organization** unticked. If a Global Reader gets **Need admin approval**, have a Global Administrator run it.

**2. Get the partner's result.** Their admin does Steps 3 to 5 with *your* tenant ID as the partner and sends you their CSV or a screenshot.

**3. Go / no-go.** Continue to Step 6 only when **both** have no FAIL. Keep both CSVs for the change record.

## Step 6: Cut over and validate

**Old configuration takes precedence over XTAP**, so testing with it still active proves nothing. Cut over one pairing at a time, with both admins switching together: users lose cross-tenant free/busy until the test passes or you roll back.

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

Microsoft's guide disables the whole Sharing Policy instead. That also breaks every other rule in it, for every mailbox on it (including the Default policy), so only do that if the policy has nothing else in it.

**2. Test, in both directions:**

- **Free/Busy**: a user in A adds a user from B to a new meeting in Outlook. Scheduling Assistant should show B's availability at the level B granted. Then repeat from B to A.
- **MailTips** (if granted): address a partner user who has automatic replies on; the MailTip should appear before sending.
- **Calendar Sharing** (if granted): share a calendar with a partner user and confirm they can open it.
- **Group scoping** (if used): confirm a user outside the group shows no availability to the partner.
- **Timing**: changes aren't always instant; wait and retry before rolling back, and note how long it took.
- **Compare with Step 1**: the new path should match or exceed the old one.

**3. If it doesn't work, roll back** on the tenant that isn't showing data (the one being looked *at*):

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

Cut over each pairing when it's ready; don't wait to do them all at once.

## Step 7: Clean up old configuration

After a burn-in with no issues (e.g., 2 to 4 weeks), remove what you turned off:

```powershell
Remove-OrganizationRelationship -Identity "<PartnerOrgRelationship>"

# Only if the policy is now unused (no rules left that anyone needs, and no mailboxes assigned)
Remove-SharingPolicy -Identity "<SharingPolicyName>"
```

Delete the Availability Address Space backups after the burn-in.

## Per-pairing tracking

One row per pairing from Step 1, same number in both tables.

**Pairings:**

| # | Op-Co A | A tenant ID | Op-Co B | B tenant ID | Level (F/B, MailTips, Calendar) |
| --- | --- | --- | --- | --- | --- |
| 1 |  |  |  |  |  |
| 2 |  |  |  |  |  |

**Status:** "Script run on A" means run in A's tenant with B as the partner.

| # | Portal checked on A and B (Step 3) | Script run on A (Step 4) | Script run on B (Step 4) | Both checks clean (Step 5) | Old config off on both (Step 6) | Validated (Step 6) | Old config removed (Step 7) |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | ☐ | ☐ | ☐ | ☐ | ☐ | ☐ | ☐ |
| 2 | ☐ | ☐ | ☐ | ☐ | ☐ | ☐ | ☐ |

## Appendix: Manual PowerShell steps

Use these instead of the Step 4 script only for group-limited grants, or when the script can't be run. They make the same Graph calls.

### Sign in

Same sign-in as the scripts (account picker or browser; add `-UseDeviceCode` if there's no browser). Run everything below in the same PowerShell window.

```powershell
$tenantId = "<your-tenant-id>"  # the op-co tenant you are configuring right now
Connect-MgGraph -TenantId $tenantId -Scopes Policy.ReadWrite.CrossTenantAccess, Policy.ReadWrite.CrossTenantCapability -NoWelcome
(Get-MgContext).TenantId  # confirm this matches $tenantId before changing anything
```

Accept the consent prompt the first time, as in Step 4. When you're finished, especially on a shared machine, run `Disconnect-MgGraph` to sign out.

### Turn on M365 Collaboration trust (Layer 2)

**Check first** with [Test-XtapPartner.ps1](Test-XtapPartner.ps1): this replaces the current setting, so a limited or blocked trust would silently become "all users".

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

Invoke-MgGraphRequest -Method PATCH -Uri $partnerUri -Body $body -ContentType "application/json"
```

A 404 means the partner isn't in the portal yet (Step 3).

### Grant a capability (Layer 3)

Once per capability, from the [Step 4 table](#choose-capabilities):

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

Invoke-MgGraphRequest -Method POST -Body $body -ContentType "application/json" `
    -Uri "https://graph.microsoft.com/beta/policies/crossTenantAccessPolicy/partners/$partnerTenantId/m365Capabilities"
```

Then continue with [Step 5](#step-5-check-your-side-and-confirm-the-partners-side).

## Key dates and references

- **October 1, 2026**: EWS soft block begins (gradual rollout); old cross-tenant sharing starts breaking tenant by tenant.
- **April 1, 2027**: EWS hard shutdown, no exceptions.
- [Retirement of Exchange Web Services in Exchange Online](https://techcommunity.microsoft.com/blog/exchange/retirement-of-exchange-web-services-in-exchange-online/3924440) (Exchange Team Blog)
- [Cross-tenant Free/Busy, MailTips, and Calendar Sharing are moving to Cross-Tenant Access Policy](https://techcommunity.microsoft.com/blog/exchange/cross-tenant-freebusy-mailtips-and-calendar-sharing-are-moving-to-cross-tenant-a/4545169) (Exchange Team Blog; rollout schedule)
- **Message Center MC1446796**: "Migrate Free/Busy, MailTips, and Calendar Sharing before EWS deprecation".
- [Migrate to Microsoft 365 Cross-Tenant Access Policy for sharing Free/Busy, Calendars, and MailTips](https://learn.microsoft.com/en-us/exchange/sharing/migrate-to-m365-xtap) (Microsoft Learn; source of truth for the Graph calls)
- [Cross-tenant access settings (Microsoft Entra External ID)](https://learn.microsoft.com/en-us/entra/external-id/cross-tenant-access-settings-b2b-collaboration) (Microsoft Learn; Layer 1)
- [Help us shape Exchange Server on-premises to different online org Free/Busy after EWS retirement](https://techcommunity.microsoft.com/blog/exchange/help-us-shape-exchange-server-on-premises-to-different-online-org-freebusy-after/4549691) (only for Exchange hybrid)
