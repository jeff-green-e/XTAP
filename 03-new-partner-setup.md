# Cross-Tenant Calendar Sharing: New Partner Setup

Last updated: September 28, 2026. If you haven't read it yet, start with [How It Works](01-how-it-works.md) for the concepts behind these steps.

## When to use this doc

Use this runbook when two tenants need to share Free/Busy, MailTips, or calendars and **neither side has any existing EWS-era configuration for the other**. Typical cases:

- A newly acquired or newly created op-co that needs to share with the others.
- Two existing op-cos that never shared before and now need to.
- A new external partner hosted in Microsoft 365 that the business has approved for calendar sharing.

If either tenant already has an Organization Relationship, Sharing Policy rule, or Availability Address Space for the other, use the [migration checklist](02-migration-checklist.md) instead. Old configuration takes precedence over XTAP, so a stray leftover entry will hide whether the new setup works.

Net-new setup is simpler than migration: there's nothing to discover, nothing to run in parallel, and nothing to decommission. It's a check of the partner entry in the portal, Layers 2 and 3 in PowerShell on each side, then a test.

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

- Their Entra **Tenant ID** (Entra admin center → Overview → Tenant ID). Domain names aren't needed.
- The name of an admin who will configure their side and test with you.
- Confirmation that they're hosted in Exchange Online. XTAP doesn't cover on-premises or hybrid free/busy.

**Confirm in your own tenant:**

- **The rollout has reached both tenants.** XTAP for Free/Busy, MailTips, and Calendar Sharing is still rolling out; check Message Center (MC1446796).
- **No leftover EWS-era config for this partner.** Run the Step 1 discovery commands from the [migration checklist](02-migration-checklist.md#step-1-discovery). If anything names the partner's domains, including a wildcard `*` Sharing Policy rule, handle it through the migration checklist first.
- **Roles:** Global Administrator to create the M365 Collaboration trust (Step 3). Global Administrator or Exchange Administrator can grant capabilities (Step 4). Reviewing or adding the partner organization in the portal (Step 1) needs Security Administrator or Global Administrator.
- **Scoping group (optional):** if only some of your users should be visible to the partner, create a security group of those users now and note its object ID.

## Step 1: Verify the partner organization in Entra admin center (Layer 1)

Layer 1 is configured in the portal, not with PowerShell. In most cases the partner is already there and you only need to check it.

1. Go to **Entra admin center → Entra ID → External Identities → Cross-tenant access settings → Organizational settings**.
2. Look for the partner in the list, by name or Tenant ID.
   - **Listed**: go to step 3.
   - **Not listed**: select **Add organization**, enter the partner's Tenant ID, and select **Add**. The new entry inherits your default settings; don't change anything else here unless your B2B standards call for it.
3. Open the partner's **Inbound access** and check the **Trust settings** tab against your environment's standard: *Trust multifactor authentication from Microsoft Entra tenants* is on; compliant and hybrid-joined device trust are off. Fix it here if it doesn't match.

Trust settings govern B2B guest sign-ins. Calendar sharing doesn't depend on them, so a mismatch won't break Free/Busy, but this is the natural moment to confirm the entry is correct.

## Step 2: Sign in

Layers 2 and 3 have no portal UI yet, so the rest of the setup uses PowerShell. Use the device-code sign-in from the [migration checklist, Step 2](02-migration-checklist.md#step-2-prerequisites-and-sign-in). Set `$tenantId` to *your* tenant and sign in as a Global Administrator. The consent prompt asks for `Policy.ReadWrite.CrossTenantAccess` and `Policy.ReadWrite.CrossTenantCapability`; accept both. You'll reuse `$headers` in the steps below.

## Step 3: Turn on M365 Collaboration trust (Layer 2)

This adds M365 Collaboration trust for all users to the partner entry you verified in Step 1. It doesn't change any Layer 1 settings.

```powershell
$partnerTenantId = "<partner-tenant-id>"  # the partner you're granting access to; also used in Step 4
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

## Step 4: Grant capabilities (Layer 3)

Run once per capability you agreed to share. Each call grants the partner's users inbound access to that capability in your tenant.

```powershell
$capability = "crossTenantCalendarAvailabilityBasic"  # from the table in "Before you start"

# Who in YOUR tenant the partner can see. Use one of these:
$scope = @{ resourceId = "All"; resourceType = "user" }             # all users
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

Check what's now configured for the partner:

```powershell
$uri = "https://graph.microsoft.com/beta/policies/crossTenantAccessPolicy/partners/$partnerTenantId"
(Invoke-RestMethod -Method Get -Uri $uri -Headers $headers).m365CollaborationInbound | ConvertTo-Json -Depth 6
(Invoke-RestMethod -Method Get -Uri "$uri/m365Capabilities" -Headers $headers).value | ConvertTo-Json -Depth 6
```

## Step 5: The partner configures their side

Your configuration only lets the partner see *your* users. For your users to see theirs, the partner's admin runs Steps 1 to 4 in *their* tenant, with *your* Tenant ID as `$partnerTenantId`.

Send them:

- Your Tenant ID.
- What you granted them (capability names, and whether it's scoped to a group).
- What you'd like them to grant you.
- A link to this doc, or the [Microsoft Learn guide](https://learn.microsoft.com/en-us/exchange/sharing/migrate-to-m365-xtap) if they're outside the organization (its Part 2 covers the same calls).

## Step 6: Validate

Test in both directions once both sides are done. With no old configuration in the way, results reflect XTAP alone.

- **Free/Busy**: a user in your tenant creates a meeting in Outlook (desktop or web) and adds a partner user. Scheduling Assistant should show their availability at the level *their* tenant granted. Then have a partner user do the same with one of your users.
- **MailTips** (if granted): address a partner user who has automatic replies turned on; the MailTip should appear before sending.
- **Calendar Sharing** (if granted): share a calendar with a partner user and confirm they can open it at the granted level.
- **Group scoping** (if used): confirm a user *outside* the group shows no availability to the partner.
- **Timing**: changes aren't always instant. If a test fails right after setup, wait and retry before troubleshooting.

**If a direction doesn't work**, the fix is in the tenant being looked *at*, not the one doing the looking. If your users can't see the partner, check the partner's configuration.

## Changing or removing sharing later

- **Change the level**: grant the new capability (Step 4), confirm it works, then remove the old one.
- **Stop sharing with a partner** (for example after a divestiture): remove the capabilities from the partner entry, then remove its M365 Collaboration trust. Your users stay hidden from the partner as soon as the capabilities are gone, whatever the partner has configured on their side. See the [M365 cross-tenant access policy Graph API overview](https://learn.microsoft.com/en-us/graph/api/resources/m365-cross-tenant-access-policy-overview) for the update and delete calls.

## Tenant-wide defaults (use with care)

Capabilities can also be set on the **default** policy instead of a partner entry. A default capability applies to *every* Microsoft 365 organization that doesn't have its own partner entry, not just the op-cos. For sharing between op-cos, always use partner entries as above.

Anonymous calendar publishing (sharing a calendar to an internet URL) can only be set on the default policy. Treat it as a separate decision with its own approval.

## Per-partner tracking

| Partner | Partner tenant ID | We grant them | They grant us | Layer 1 verified | Our Layer 2 | Our Layer 3 | Their side done | Validated both ways |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
|  |  |  |  | ☐ | ☐ | ☐ | ☐ | ☐ |
|  |  |  |  | ☐ | ☐ | ☐ | ☐ | ☐ |

## References

- [Migrate to Microsoft 365 Cross-Tenant Access Policy for sharing Free/Busy, Calendars, and MailTips](https://learn.microsoft.com/en-us/exchange/sharing/migrate-to-m365-xtap): Microsoft Learn. Part 2 is the source for the calls and capability names used here.
- [Microsoft 365 cross-tenant access policy Graph API overview](https://learn.microsoft.com/en-us/graph/api/resources/m365-cross-tenant-access-policy-overview): Microsoft Learn reference for the partner, capability, and default policy resources.
- [Cross-tenant access settings (Microsoft Entra External ID)](https://learn.microsoft.com/en-us/entra/external-id/cross-tenant-access-settings-b2b-collaboration): Microsoft Learn reference for the Layer 1 B2B trust settings.
