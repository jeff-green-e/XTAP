# Runbook: Set Up New Sharing

Last updated: September 29, 2026. If you haven't read it yet, start with [How It Works](01-how-it-works.md) for the concepts behind these steps.

## When to use this doc

Use this runbook when two tenants need to share Free/Busy, MailTips, or calendars and **neither side has any existing EWS-era configuration for the other**. Typical cases:

- A newly acquired or newly created op-co that needs to share with the others.
- Two existing op-cos that never shared before and now need to.
- A new external partner hosted in Microsoft 365 that the business has approved for calendar sharing.

If either tenant already has an Organization Relationship, Sharing Policy rule, or Availability Address Space for the other, use [Migrate Existing Sharing](02-migrate-existing-sharing.md) instead. Old configuration takes precedence over XTAP, so a stray leftover entry will hide whether the new setup works.

Net-new setup is simpler than migration: there's nothing to discover, no old configuration to turn off, and nothing to clean up. On each side it's a check of the partner entry in the portal, one script run, and a configuration check; then both sides test together.

## Before you start

**Agree with the partner on what each side shares.** Each tenant decides only what the *other* side may see of it, and the two sides don't have to match (see [inbound, per tenant](01-how-it-works.md#who-configures-what-inbound-per-tenant)). Pick capabilities from this table. Names are case-sensitive.

| Need | Capability |
| --- | --- |
| See when people are free or busy (times only) | `crossTenantCalendarAvailabilityBasic` |
| Free/busy plus meeting subject and location | `crossTenantCalendarAvailabilityLimitedDetails` |
| MailTips that prevent an NDR, plus automatic replies | `crossTenantMailTipsLimited` |
| All MailTips (out of office, automatic replies, large audience, custom) | `crossTenantMailTipsAll` |
| Users can share their calendar with partner users: times only | `crossTenantCalendarSharingFreeBusySimple` |
| Users can share their calendar: times, subject, location | `crossTenantCalendarSharingFreeBusyDetail` |
| Users can share their full calendar | `crossTenantCalendarSharingFreeBusyReviewer` |

The Scheduling Assistant scenario ("add a colleague from the other op-co and see when they're free") only needs a Free/Busy capability. Grant MailTips and Calendar Sharing only if the business asks for them.

**Collect from the partner:**

- Their Entra **Tenant ID** (Entra admin center → Identity → Overview → Tenant ID). Domain names aren't needed.
- The name of an admin who will configure their side and test with you.
- Confirmation that they're hosted in Exchange Online. XTAP doesn't cover on-premises or hybrid free/busy.

**Confirm in your own tenant:**

- **The rollout has reached both tenants.** XTAP for Free/Busy, MailTips, and Calendar Sharing is still rolling out; check Message Center (MC1446796).
- **No leftover EWS-era config for this partner.** Run the Step 1 discovery commands from [Migrate Existing Sharing](02-migrate-existing-sharing.md#step-1-discovery). If anything names the partner's domains, including a wildcard `*` Sharing Policy rule, switch to that runbook.
- **Roles:** Security Administrator or Global Administrator for the portal check (Step 1). **Global Administrator** to run the enable script (Step 2), because it turns on M365 Collaboration trust. Global Reader is enough for the configuration check (Step 3).
- **Scoping group (optional):** if only some of your users should be visible to the partner, create a security group of those users now and note its object ID. The script always grants to all users, so a group-limited grant uses the [manual steps](#appendix-manual-powershell-steps) instead.

## Step 1: Verify the partner organization in Entra admin center (Layer 1)

Layer 1 is configured in the portal, not with PowerShell. In most cases the partner is already there and you only need to check it.

1. Go to **Entra admin center → Identity → External Identities → Cross-tenant access settings → Organizational settings**.
2. Look for the partner in the list, by name or Tenant ID.
   - **Listed**: go to step 3.
   - **Not listed**: select **Add organization**, enter the partner's Tenant ID, and select **Add**. The new entry inherits your default settings; don't change anything else here unless your B2B standards call for it.
3. Open the partner's **Inbound access** and check the **Trust settings** tab against your environment's standard: *Trust multifactor authentication from Microsoft Entra tenants* is on; compliant and hybrid-joined device trust are off. Fix it here if it doesn't match.

Trust settings govern B2B guest sign-ins. Calendar sharing doesn't depend on them, so a mismatch won't break Free/Busy, but this is the natural moment to confirm the entry is correct.

## Step 2: Turn on sharing with Enable-XtapPartner.ps1 (Layers 2 and 3)

Layers 2 and 3 have no portal UI yet, so this step uses [Enable-XtapPartner.ps1](Enable-XtapPartner.ps1). It signs you in, turns on M365 Collaboration trust for the partner (Layer 2), and grants the capabilities you agreed (Layer 3). It never changes the Layer 1 settings you checked in Step 1.

### Get ready

- **The script**: download `Enable-XtapPartner.ps1` and `Test-XtapPartner.ps1` from this repo into one folder. If Windows blocks a downloaded file, run `Unblock-File .\Enable-XtapPartner.ps1` (and the same for the test script).
- **PowerShell**: PowerShell 7 (Windows PowerShell 5.1 should also work), in a normal (not elevated) window, opened in that folder. No modules to install. If the execution policy stops the script, run `Set-ExecutionPolicy -Scope Process Bypass`; that only affects this window.
- **Values**:
  - `-TenantId`: *your* tenant ID, the tenant whose users the partner will see.
  - `-PartnerTenantId`: the partner's tenant ID.
  - `-Capability`: only if you're granting more than Free/Busy times. Use the exact names from the table in [Before you start](#before-you-start), separated by commas.
- **A browser** where you can sign in as a Global Administrator of your tenant.

### Dry run

Run it with `-WhatIf` first. It signs in and reads the current settings, but changes nothing:

```powershell
.\Enable-XtapPartner.ps1 -TenantId <your-tenant-id> -PartnerTenantId <partner-tenant-id> -WhatIf
```

1. The script prints a URL and a code. Open the URL in a browser, enter the code, and sign in as a Global Administrator of **your** tenant.
2. The first time in a tenant, you're asked to consent to `Policy.ReadWrite.CrossTenantAccess` and `Policy.ReadWrite.CrossTenantCapability` for Microsoft Graph Command Line Tools. Accept. This only lets the tool act with the admin rights you already have.
3. Back in PowerShell, check the "What if" lines. For a new partner you should see one for turning on M365 Collaboration trust and one for each capability:

```text
What if: Performing the operation "Turn on M365 Collaboration trust for all users" on target "partner <partner-tenant-id>".
What if: Performing the operation "Grant crossTenantCalendarAvailabilityBasic (all users)" on target "partner <partner-tenant-id>".
```

If the script stops with an error instead, see [If the script stops](#if-the-script-stops).

### Run it

Run the same command without `-WhatIf`, and sign in again the same way. To grant more than Free/Busy times, add `-Capability`:

```powershell
# Free/Busy times only (the default)
.\Enable-XtapPartner.ps1 -TenantId <your-tenant-id> -PartnerTenantId <partner-tenant-id>

# Example: Free/Busy times and all MailTips
.\Enable-XtapPartner.ps1 -TenantId <your-tenant-id> -PartnerTenantId <partner-tenant-id> `
    -Capability crossTenantCalendarAvailabilityBasic, crossTenantMailTipsAll
```

A successful run ends with a summary like this:

```text
Signed in.
Layer 2: M365 Collaboration trust turned on.
Layer 3: granted crossTenantCalendarAvailabilityBasic to partner (all users).

Partner <partner-tenant-id>, as configured in tenant <your-tenant-id>
  M365 Collaboration trust: allowed for all users
  Capability: crossTenantCalendarAvailabilityBasic: allowed for all users
```

"Already on" or "already configured, no change" lines are fine too. They mean that part was set up before, and the script left it alone. Running the script again is always safe, so you can add a capability later the same way.

### If the script stops

| Message | What it means | What to do |
| --- | --- | --- |
| `No cross-tenant access entry for partner …` | The partner isn't under Organizational settings. | Add it in the portal ([Step 1](#step-1-verify-the-partner-organization-in-entra-admin-center-layer-1)), then run the script again. |
| `Layer 2: M365 Collaboration trust for this partner is already set to something other than 'allowed for all users'` | Someone has limited or blocked the trust for this partner. The script won't widen it. | Find out who set it and why before changing anything. The message shows the current setting. |
| `403` / `Authorization_RequestDenied` | The account isn't a Global Administrator, or the consent prompt was declined. | Sign in with a Global Administrator account and accept the consent prompt. |
| `The sign-in code expired` | Sign-in wasn't finished in time (about 15 minutes). | Run the script again. |
| An `AADSTS…` error during sign-in | Usually the wrong `-TenantId`, or signing in with an account from a different tenant. | Check the tenant ID, and sign in with an account from that tenant. |
| `Cannot validate argument on parameter 'Capability'` | A capability name is misspelled or outdated. | Use the exact name from the table in [Before you start](#before-you-start). |

## Step 3: Check your side

Run the read-only check against the same partner, listing the capabilities you granted:

```powershell
.\Test-XtapPartner.ps1 -TenantId <your-tenant-id> -PartnerTenantId <partner-tenant-id> `
    -ExpectedCapability crossTenantCalendarAvailabilityBasic
```

It signs in the same way (Global Reader is enough) and should show **PASS** for Partner entry, Trust settings, M365 Collab trust, and each expected capability. A WARN on Trust settings means Step 1 doesn't match the environment standard; fix it in the portal. It doesn't block calendar sharing. Fix any FAIL before moving on. Add `-CsvPath .\xtap-check.csv` to keep a copy for the change record.

## Step 4: The partner configures their side

Your setup only lets the partner see *your* users. For your users to see theirs, the partner's admin does Steps 1 to 3 in *their* tenant, with *your* Tenant ID as `-PartnerTenantId`.

Send them:

- Your Tenant ID.
- What you granted them (capability names, and whether it's scoped to a group).
- What you'd like them to grant you.
- A link to this doc and the two scripts, or the [Microsoft Learn guide](https://learn.microsoft.com/en-us/exchange/sharing/migrate-to-m365-xtap) if they're outside the organization (its Part 2 covers the same calls).

## Step 5: Validate

Test in both directions once both sides have a clean Step 3 check. With no old configuration in the way, results reflect XTAP alone. The script checks configuration only; these Outlook tests are what prove it works for users.

- **Free/Busy**: a user in your tenant creates a meeting in Outlook (desktop or web) and adds a partner user. Scheduling Assistant should show their availability at the level *their* tenant granted. Then have a partner user do the same with one of your users.
- **MailTips** (if granted): address a partner user who has automatic replies turned on; the MailTip should appear before sending.
- **Calendar Sharing** (if granted): share a calendar with a partner user and confirm they can open it at the granted level.
- **Group scoping** (if used): confirm a user *outside* the group shows no availability to the partner.
- **Timing**: changes aren't always instant. If a test fails right after setup, wait and retry before troubleshooting.

**If a direction doesn't work**, the fix is in the tenant being looked *at*, not the one doing the looking. If your users can't see the partner, check the partner's configuration.

## Changing or removing sharing later

- **Change the level**: grant the new capability (run the Step 2 script with `-Capability`), confirm it works, then remove the old one.
- **Stop sharing with a partner** (for example after a divestiture): remove the capabilities from the partner entry, then remove its M365 Collaboration trust. Your users stay hidden from the partner as soon as the capabilities are gone, whatever the partner has configured on their side. See the [M365 cross-tenant access policy Graph API overview](https://learn.microsoft.com/en-us/graph/api/resources/m365-cross-tenant-access-policy-overview) for the update and delete calls.

## Tenant-wide defaults (use with care)

Capabilities can also be set on the **default** policy instead of a partner entry. A default capability applies to *every* Microsoft 365 organization that doesn't have its own partner entry, not just the op-cos. For sharing between op-cos, always use partner entries as above.

Anonymous calendar publishing (sharing a calendar to an internet URL) can only be set on the default policy. Treat it as a separate decision with its own approval.

## Per-partner tracking

| Partner | Partner tenant ID | We grant them | They grant us | Portal checked (Step 1) | Script run (Step 2) | Our check clean (Step 3) | Their side clean | Validated both ways |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
|  |  |  |  | ☐ | ☐ | ☐ | ☐ | ☐ |
|  |  |  |  | ☐ | ☐ | ☐ | ☐ | ☐ |

## Appendix: Manual PowerShell steps

Use these instead of the Step 2 script only when you need something it doesn't do, such as limiting a grant to a security group, or when the script can't be run. They make the same Graph calls.

**Sign in.** Run the device-code sign-in from [Migrate Existing Sharing, Appendix](02-migrate-existing-sharing.md#sign-in), with `$tenantId` set to *your* tenant, signing in as a Global Administrator. Run everything below **in the same PowerShell window**: the sign-in sets `$headers`, which these blocks use. If you close the window or the token expires (after roughly 60 to 90 minutes), sign in again.

**Turn on M365 Collaboration trust (Layer 2).** First check that it isn't already set for this partner: this PATCH replaces whatever is there, so a setting someone limited to specific users, or blocked, would silently become "all users". [Test-XtapPartner.ps1](Test-XtapPartner.ps1) shows the current value. If it's already set to anything other than all users, review it with whoever configured it first.

```powershell
$partnerTenantId = "<partner-tenant-id>"  # the partner you're granting access to; also used below
$partnerUri      = "https://graph.microsoft.com/beta/policies/crossTenantAccessPolicy/partners/$partnerTenantId"

# Stop if the partner entry doesn't exist yet
try {
    Invoke-RestMethod -Method Get -Uri $partnerUri -Headers $headers | Out-Null
} catch {
    if ([int]$_.Exception.Response.StatusCode -eq 404) {
        throw "No partner entry for $partnerTenantId. Add the organization in Entra admin center first (Step 1)."
    }
    throw
}

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

**Grant a capability (Layer 3).** Run once per capability:

```powershell
$capability = "crossTenantCalendarAvailabilityBasic"  # from the table in "Before you start"

# Who in YOUR tenant the partner can see. Use one of these:
$scope = @{ resourceId = "All"; resourceType = "user" }             # all users (for Calendar Sharing capabilities, use resourceType = "group")
# $scope = @{ resourceId = "<group-object-id>"; resourceType = "group" }  # only members of a security group

$body = @{
    "@odata.type" = "#microsoft.graph.$capability"
    inboundAccess = @{
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

Then continue with [Step 3](#step-3-check-your-side).

## References

- [Migrate to Microsoft 365 Cross-Tenant Access Policy for sharing Free/Busy, Calendars, and MailTips](https://learn.microsoft.com/en-us/exchange/sharing/migrate-to-m365-xtap): Microsoft Learn. Part 2 is the source for the calls and capability names used here.
- [Microsoft 365 cross-tenant access policy Graph API overview](https://learn.microsoft.com/en-us/graph/api/resources/m365-cross-tenant-access-policy-overview): Microsoft Learn reference for the partner, capability, and default policy resources.
- [Cross-tenant access settings (Microsoft Entra External ID)](https://learn.microsoft.com/en-us/entra/external-id/cross-tenant-access-settings-b2b-collaboration): Microsoft Learn reference for the Layer 1 B2B trust settings.
