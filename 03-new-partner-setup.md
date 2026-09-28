# Cross-Tenant Calendar Sharing: New Partner Setup

Last updated: September 28, 2026. If you haven't read it yet, start with [How It Works](01-how-it-works.md) for the concepts behind these steps.

## When to use this doc

Use this runbook when two tenants need to share Free/Busy, MailTips, or calendars and **neither side has any existing EWS-era configuration for the other**. Typical cases:

- A newly acquired or newly created op-co that needs to share with the others.
- Two existing op-cos that never shared before and now need to.
- A new external partner hosted in Microsoft 365 that the business has approved for calendar sharing.

If either tenant already has an Organization Relationship, Sharing Policy rule, or Availability Address Space for the other, use the [migration checklist](02-migration-checklist.md) instead. Old configuration takes precedence over XTAP, so a stray leftover entry will hide whether the new setup works.

Net-new setup is simpler than migration: there's nothing to discover, nothing to run in parallel, and nothing to decommission. It's Layers 2 and 3 on each side, then a test.

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
- **Roles:** Global Administrator to create the M365 Collaboration trust (Step 2 below). Global Administrator or Exchange Administrator can grant capabilities (Step 3).
- **Scoping group (optional):** if only some of your users should be visible to the partner, create a security group of those users now and note its object ID.

## Step 1: Sign in

Use the device-code sign-in from the [migration checklist, Step 2](02-migration-checklist.md#step-2-prerequisites-and-sign-in). Set `$tenantId` to *your* tenant and sign in as a Global Administrator. The consent prompt asks for `Policy.ReadWrite.CrossTenantAccess` and `Policy.ReadWrite.CrossTenantCapability`; accept both. You'll reuse `$headers` in the steps below.

## Step 2: Create the partner entry and M365 Collaboration trust (Layers 1 and 2)

This creates the partner entry if it doesn't exist yet, then turns on M365 Collaboration trust for all users. If the partner already has a Layer 1 B2B entry, this only adds the M365 Collaboration setting to it. A newly created entry inherits your tenant's default B2B settings, so it doesn't open up B2B access beyond what your defaults already allow.

```powershell
$partnerTenantId = "<partner-tenant-id>"  # the partner you're granting access to; also used in Step 3
$partnersUri     = "https://graph.microsoft.com/beta/policies/crossTenantAccessPolicy/partners"

# M365 Collaboration trust for all users. Narrower scoping is done per capability in Step 3.
$trust = @{
    m365CollaborationInbound = @{
        users = @{
            accessType = "allowed"
            targets    = @(@{ target = "AllUsers"; targetType = "user" })
        }
    }
}

# Is there already a partner entry (Layer 1) for this tenant?
$existing = $null
try {
    $existing = Invoke-RestMethod -Method Get -Uri "$partnersUri/$partnerTenantId" -Headers $headers
} catch {
    if ([int]$_.Exception.Response.StatusCode -ne 404) { throw }
}

if ($existing) {
    # Add M365 Collaboration trust to the existing entry
    Invoke-RestMethod -Method Patch -Uri "$partnersUri/$partnerTenantId" `
        -Headers $headers -ContentType "application/json" -Body ($trust | ConvertTo-Json -Depth 6)
} else {
    # Create the partner entry with M365 Collaboration trust
    $trust.tenantId = $partnerTenantId
    Invoke-RestMethod -Method Post -Uri $partnersUri `
        -Headers $headers -ContentType "application/json" -Body ($trust | ConvertTo-Json -Depth 6)
}
```

MFA and device trust settings (`inboundTrust`) are Layer 1 B2B settings and aren't needed for calendar sharing. Leave them as your B2B policy already has them.

## Step 3: Grant capabilities (Layer 3)

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

## Step 4: The partner configures their side

Your configuration only lets the partner see *your* users. For your users to see theirs, the partner's admin runs Steps 1 to 3 in *their* tenant, with *your* Tenant ID as `$partnerTenantId`.

Send them:

- Your Tenant ID.
- What you granted them (capability names, and whether it's scoped to a group).
- What you'd like them to grant you.
- A link to this doc, or the [Microsoft Learn guide](https://learn.microsoft.com/en-us/exchange/sharing/migrate-to-m365-xtap) if they're outside the organization (its Part 2 covers the same calls).

## Step 5: Validate

Test in both directions once both sides are done. With no old configuration in the way, results reflect XTAP alone.

- **Free/Busy**: a user in your tenant creates a meeting in Outlook (desktop or web) and adds a partner user. Scheduling Assistant should show their availability at the level *their* tenant granted. Then have a partner user do the same with one of your users.
- **MailTips** (if granted): address a partner user who has automatic replies turned on; the MailTip should appear before sending.
- **Calendar Sharing** (if granted): share a calendar with a partner user and confirm they can open it at the granted level.
- **Group scoping** (if used): confirm a user *outside* the group shows no availability to the partner.
- **Timing**: changes aren't always instant. If a test fails right after setup, wait and retry before troubleshooting.

**If a direction doesn't work**, the fix is in the tenant being looked *at*, not the one doing the looking. If your users can't see the partner, check the partner's configuration.

## Changing or removing sharing later

- **Change the level**: grant the new capability (Step 3), confirm it works, then remove the old one.
- **Stop sharing with a partner** (for example after a divestiture): remove the capabilities from the partner entry, then remove its M365 Collaboration trust. Your users stay hidden from the partner as soon as the capabilities are gone, whatever the partner has configured on their side. See the [M365 cross-tenant access policy Graph API overview](https://learn.microsoft.com/en-us/graph/api/resources/m365-cross-tenant-access-policy-overview) for the update and delete calls.

## Tenant-wide defaults (use with care)

Capabilities can also be set on the **default** policy instead of a partner entry. A default capability applies to *every* Microsoft 365 organization that doesn't have its own partner entry, not just the op-cos. For sharing between op-cos, always use partner entries as above.

Anonymous calendar publishing (sharing a calendar to an internet URL) can only be set on the default policy. Treat it as a separate decision with its own approval.

## Per-partner tracking

| Partner | Partner tenant ID | We grant them | They grant us | Our Layer 2 | Our Layer 3 | Their side done | Validated both ways |
| --- | --- | --- | --- | --- | --- | --- | --- |
|  |  |  |  | ☐ | ☐ | ☐ | ☐ |
|  |  |  |  | ☐ | ☐ | ☐ | ☐ |

## References

- [Migrate to Microsoft 365 Cross-Tenant Access Policy for sharing Free/Busy, Calendars, and MailTips](https://learn.microsoft.com/en-us/exchange/sharing/migrate-to-m365-xtap): Microsoft Learn. Part 2 is the source for the calls and capability names used here.
- [Microsoft 365 cross-tenant access policy Graph API overview](https://learn.microsoft.com/en-us/graph/api/resources/m365-cross-tenant-access-policy-overview): Microsoft Learn reference for the partner, capability, and default policy resources.
- [Cross-tenant access settings (Microsoft Entra External ID)](https://learn.microsoft.com/en-us/entra/external-id/cross-tenant-access-settings-b2b-collaboration): Microsoft Learn reference for the Layer 1 B2B trust settings.
