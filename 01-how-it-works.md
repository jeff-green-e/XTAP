# Cross-Tenant Calendar Sharing: How It Works

Read this first. It helps you pick a runbook and explains what's changing.

## Which runbook do I need?

Pick per **partner pairing**: the same op-co can need one runbook for one partner and the other for another.

| Does either tenant already share with the other through… | Use |
| --- | --- |
| An Organization Relationship, a Sharing Policy rule for the partner's domain (or a wildcard `*` rule), or an Availability Address Space | [**Migrate Existing Sharing**](02-migrate-existing-sharing.md) |
| None of those, on either side | [**Set Up New Sharing**](03-set-up-new-sharing.md) (shorter: no cutover or cleanup) |
| Not sure | Run the read-only [discovery](02-migrate-existing-sharing.md#step-1-discovery). If it finds nothing for the partner, use Set Up New Sharing |

It matters because old configuration takes precedence over XTAP: while it's active, you can't tell whether the new setup works. Both runbooks use the same two scripts; Migrate adds discovery, cutover, and cleanup.

## The short version

For end users nothing changes: Scheduling Assistant still shows the other op-co's availability. Underneath, the old path was **Exchange-to-Exchange over EWS, trusted by domain name**. The new path is **governed by Entra, trusted by tenant ID**, as part of the Cross-Tenant Access Policy you already use for B2B.

## Before and after

The old model lived inside Exchange Online: Organization Relationships (Free/Busy, MailTips) and Sharing Policies (calendar sharing) named the partner by SMTP domain, and requests went over EWS through Microsoft's federation infrastructure. That's why domain details, such as the partner's `onmicrosoft.com` domain, mattered.

The new model moves the trust decision into Entra. The partner is identified by Tenant ID, and the partner entry in the target tenant's Cross-Tenant Access Policy decides whether a request is honored.

![Old vs new request path: same four hops, different trust in the middle](images/01-before-after.svg)

## The three layers

"Cross-Tenant Access Policy" is used loosely for two things, which causes most of the confusion. The Entra B2B settings you already use are the bottom layer. Calendar sharing adds two new layers on the same partner entry, and each needs the one below it.

![The three layers of a partner entry: what each is and where it's set](images/02-three-layers.svg)

The Entra admin center grid only shows Layer 1. A partner listed there as "Configured" may not have Layers 2 and 3.

## Who configures what: inbound, per tenant

The new policy is **inbound only**: a tenant's settings decide what a partner can read from *that* tenant. Tenant A's configuration controls what Op-Co B sees of A, and vice versa. Two-way sharing needs a configuration in each tenant, and they don't have to match: A can share full detail while B shares availability only.

Think in **pairs**: every pair that shares needs a partner entry in both tenants, each pointing at the other.

![One op-co pair: each tenant's inbound policy governs what the other can read](images/03-inbound-per-tenant.svg)

When A's users can't see B, the fix is in Tenant B, not Tenant A.

## Mapping old settings to new

| Old (EWS) setting | What it did | New (M365 XTAP) equivalent |
| --- | --- | --- |
| Organization Relationship: `FreeBusyAccessLevel AvailabilityOnly` | Free/busy times only | Free/Busy **basic** capability (`crossTenantCalendarAvailabilityBasic`) |
| Organization Relationship: `FreeBusyAccessLevel LimitedDetails` | Times plus subject and location | Free/Busy **limited detail** capability |
| Organization Relationship: `MailTipsAccessLevel Limited / All` | Out-of-office and other MailTips | MailTips **limited / all** capability |
| Sharing Policy: `CalendarSharingFreeBusySimple / Detail / Reviewer` | Person-to-person calendar share invitations | Calendar Sharing **simple / detail / reviewer** capability |
| Sharing Policy: `Anonymous:` rules | Publishing a calendar to an internet URL | Anonymous variants of the calendar capabilities |
| `DomainNames` on the relationship | Identified the partner | Partner **Tenant ID** on the XTAP partner entry |
| `FreeBusyAccessScope` (a group) | Limited which of your users were visible | Optional security group scoping on the capability |
| Availability Address Space (`OrgWideFBToken`) | Org-wide free/busy trust to another tenant | Covered by the same XTAP partner entry |

Exact capability names are in each runbook's capability table.

## Where each piece lives

| Piece | Where you work with it | Notes |
| --- | --- | --- |
| Layer 1: Entra B2B partner entry | Entra admin center → Identity → External Identities → Cross-tenant access settings | Existing grid; only MFA is trusted inbound in this environment |
| Layer 2: M365 Collaboration trust | Microsoft Graph (beta) | No portal UI yet |
| Layer 3: M365 capabilities | Microsoft Graph (beta) | No portal UI yet |
| Old Organization Relationships / Sharing Policies | Exchange Online PowerShell | Used for discovery, then disabled and removed |
| Proof it works | Outlook Scheduling Assistant, MailTips, calendar share invites | Test each pair in both directions |

## Common misconceptions

- **"We already have a cross-tenant access policy for them."** That's probably just Layer 1 (B2B), which doesn't carry Free/Busy. Layers 2 and 3 are separate.
- **"We need their onmicrosoft.com domain."** Not anymore. The Tenant ID is the only identifier.
- **"Configuring our side turns on sharing both ways."** It only controls what the partner can read from you. They configure their side for you to see them.
- **"This touches Exchange hybrid."** It doesn't. This covers tenant-to-tenant sharing in Exchange Online only.
- **"Once EWS is blocked, the old settings are harmless."** While active, they take precedence over XTAP and hide whether the new setup works. Disable them to test, and remove them after a burn-in.

## References

- [Migrate to Microsoft 365 Cross-Tenant Access Policy for sharing Free/Busy, Calendars, and MailTips](https://learn.microsoft.com/en-us/exchange/sharing/migrate-to-m365-xtap) (Microsoft Learn)
- [Cross-tenant Free/Busy, MailTips, and Calendar Sharing are moving to Cross-Tenant Access Policy](https://techcommunity.microsoft.com/blog/exchange/cross-tenant-freebusy-mailtips-and-calendar-sharing-are-moving-to-cross-tenant-a/4545169) (Exchange Team Blog, MC1446796)
- [Cross-tenant access settings](https://learn.microsoft.com/en-us/entra/external-id/cross-tenant-access-settings-b2b-collaboration) (Microsoft Learn, Layer 1)
- [Retirement of Exchange Web Services in Exchange Online](https://techcommunity.microsoft.com/blog/exchange/retirement-of-exchange-web-services-in-exchange-online/3924440) (Exchange Team Blog)
