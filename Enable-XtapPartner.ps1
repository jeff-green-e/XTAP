<#
.SYNOPSIS
    Turns on M365 Collaboration trust (Layer 2) and grants M365 capabilities (Layer 3)
    to a partner tenant, so the partner's users can see this tenant's Free/Busy, MailTips,
    or shared calendars.

.DESCRIPTION
    Automates the PowerShell steps of the runbooks in this repo:
      - 02-migrate-existing-sharing.md, Step 4 (moving existing sharing off EWS; manual steps in its appendix)
      - 03-set-up-new-sharing.md,       Step 2 (sharing with a new partner; manual steps in its appendix)
    Follow the runbook; this script doesn't replace it.
    The manual PowerShell snippets in 02 and 03 mirror this script. If you change the
    Graph calls, sign-in, or safety checks here, update those snippets too.

    What it does NOT do:
      - Create or change the partner's cross-tenant access entry (Layer 1). Add it in the
        Entra admin center first (02 Step 3 / 03 Step 1); if it's missing, the script stops.
      - Configure the partner's side. Sharing is inbound only: running this in tenant A
        lets B's users see A. B's admin runs it in B, with A as the partner.
      - Disable old EWS-era configuration (see 02).
      - Limit a grant to a security group. It always grants to all users; for group
        scoping, use the manual capability step in the runbook.

    Requires the Microsoft.Graph.Authentication module. Signs in as you (Global
    Administrator) with Connect-MgGraph, using Microsoft's Graph Command Line Tools
    client; no app registration or secret. If this PowerShell window is already signed in
    to the same tenant with the needed permissions, that sign-in is reused. Otherwise an
    account picker or browser opens (or a device code with -UseDeviceCode). Run
    Disconnect-MgGraph when you're finished, especially on a shared machine.

    Before each change it shows what it's about to do and asks you to confirm (Y/N).
    Nothing is asked when everything is already set. Re-running is safe: settings that
    already exist are left alone, so you can run it again later to add another capability.

.PARAMETER TenantId
    Your tenant: the one whose data the partner will be allowed to see.

.PARAMETER PartnerTenantId
    The partner tenant being granted access.

.PARAMETER Capability
    One or more capabilities to grant. Default: crossTenantCalendarAvailabilityBasic
    (free/busy times only, the Scheduling Assistant case). Names come from the Microsoft
    Learn migration guide and are case-sensitive.

.PARAMETER UseDeviceCode
    Sign in with a device code instead of an account picker or browser window. Use this
    when there's no usable browser, such as a remote session.

.EXAMPLE
    # Free/busy times only (the default)
    .\Enable-XtapPartner.ps1 -TenantId <your-tenant-id> -PartnerTenantId <partner-tenant-id>

.EXAMPLE
    # Free/busy and all MailTips, in one run
    .\Enable-XtapPartner.ps1 -TenantId <your-tenant-id> -PartnerTenantId <partner-tenant-id> `
        -Capability crossTenantCalendarAvailabilityBasic, crossTenantMailTipsAll

.EXAMPLE
    # No browser available
    .\Enable-XtapPartner.ps1 -TenantId <id> -PartnerTenantId <id> -UseDeviceCode

.EXAMPLE
    # Preview only: show what would change without asking or changing anything
    .\Enable-XtapPartner.ps1 -TenantId <id> -PartnerTenantId <id> -WhatIf

.EXAMPLE
    # No confirmation prompts (e.g. when scripting several partners)
    .\Enable-XtapPartner.ps1 -TenantId <id> -PartnerTenantId <id> -Confirm:$false

.EXAMPLE
    # Also print the raw Graph responses at the end, for troubleshooting
    .\Enable-XtapPartner.ps1 -TenantId <id> -PartnerTenantId <id> -Verbose

.LINK
    https://learn.microsoft.com/en-us/exchange/sharing/migrate-to-m365-xtap
#>
# ConfirmImpact High: PowerShell asks Y/N before each change (skip with -Confirm:$false)
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [guid] $TenantId,

    [Parameter(Mandatory)]
    [guid] $PartnerTenantId,

    [ValidateSet(
        'crossTenantCalendarAvailabilityBasic',
        'crossTenantCalendarAvailabilityLimitedDetails',
        'crossTenantMailTipsLimited',
        'crossTenantMailTipsAll',
        'crossTenantCalendarSharingFreeBusySimple',
        'crossTenantCalendarSharingFreeBusyDetail',
        'crossTenantCalendarSharingFreeBusyReviewer'
    )]
    [string[]] $Capability = 'crossTenantCalendarAvailabilityBasic',

    [switch] $UseDeviceCode
)

$ErrorActionPreference = 'Stop'

if ($TenantId -eq $PartnerTenantId) {
    throw "TenantId and PartnerTenantId are the same. PartnerTenantId must be the OTHER tenant."
}

$graphBase = "https://graph.microsoft.com/beta/policies/crossTenantAccessPolicy/partners/$PartnerTenantId"

function Get-StatusCode($errorRecord) {
    try { return [int]$errorRecord.Exception.Response.StatusCode } catch { return $null }
}

function Invoke-Graph([string] $Method, [string] $Uri, [string] $Body) {
    $params = @{ Method = $Method; Uri = $Uri; OutputType = 'PSObject' }
    if ($Body) { $params.Body = $Body; $params.ContentType = 'application/json' }
    Invoke-MgGraphRequest @params
}

function Format-Capability($c) {
    # One line per capability, e.g. "crossTenantCalendarAvailabilityBasic: allowed for all users"
    $name = $c.'@odata.type' -replace '^#?microsoft\.graph\.', ''
    if (-not $c.inboundAccess.isAllowed) { return "${name}: present but not allowed" }
    $who = @($c.inboundAccess.resourceScopes.included | Where-Object { $_.resourceId }) |
        ForEach-Object { if ($_.resourceId -eq 'All') { "all users" } else { "$($_.resourceType) $($_.resourceId)" } }
    return "${name}: allowed for $(if ($who) { $who -join ', ' } else { 'nobody' })"
}

# --- Sign in (Connect-MgGraph) -------------------------------------------------------------

if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
    throw ("The Microsoft.Graph.Authentication module isn't installed. Install it with:`n" +
           "  Install-Module Microsoft.Graph.Authentication -Scope CurrentUser`nthen run this again.")
}
Import-Module Microsoft.Graph.Authentication

$scopes  = @('Policy.ReadWrite.CrossTenantAccess', 'Policy.ReadWrite.CrossTenantCapability')
$context = Get-MgContext
$reuse   = $context -and $context.TenantId -eq "$TenantId" -and
           -not ($scopes | Where-Object { $context.Scopes -notcontains $_ })

if (-not $reuse) {
    Write-Host "Sign in as a Global Administrator of tenant $TenantId. If asked for consent, leave 'Consent on behalf of your organization' unticked." -ForegroundColor Yellow
    $connect = @{ TenantId = "$TenantId"; Scopes = $scopes; NoWelcome = $true }
    if ($UseDeviceCode) { $connect.UseDeviceCode = $true }
    Connect-MgGraph @connect
    $context = Get-MgContext
}

# Cached sign-ins make it easy to land in the wrong tenant; check before changing anything
if (-not $context -or $context.TenantId -ne "$TenantId") {
    throw ("Signed in to tenant $($context.TenantId), not $TenantId. Run Disconnect-MgGraph, then run " +
           "this again and sign in with an account from tenant $TenantId.")
}
Write-Host "Signed in as $($context.Account) to tenant $TenantId." -ForegroundColor Green

# --- Check the partner entry exists (Layer 1 is managed in the portal) ---------------------

try {
    $partner = Invoke-Graph GET $graphBase
} catch {
    if ((Get-StatusCode $_) -eq 404) {
        throw ("No cross-tenant access entry for partner $PartnerTenantId. Add the organization in " +
               "Entra admin center > Identity > External Identities > Cross-tenant access settings > " +
               "Organizational settings, then run this again.")
    }
    throw
}

# --- Layer 2: M365 Collaboration trust -----------------------------------------------------

$current    = $partner.m365CollaborationInbound.users
$allUsersOn = $current.accessType -eq 'allowed' -and
              ($current.targets | Where-Object { $_.target -eq 'AllUsers' })

if ($allUsersOn) {
    Write-Host "Layer 2: M365 Collaboration trust is already on for all users. No change." -ForegroundColor Green
} elseif ($current.accessType) {
    # Someone has configured it differently (blocked, or scoped to specific users/groups).
    # Don't widen it silently.
    throw ("Layer 2: M365 Collaboration trust for this partner is already set to something other than " +
           "'allowed for all users':`n" + ($current | ConvertTo-Json -Depth 6) +
           "`nReview it with whoever configured it before changing it. This script won't overwrite it.")
} else {
    $body = @{
        m365CollaborationInbound = @{
            users = @{
                accessType = "allowed"
                targets    = @(@{ target = "AllUsers"; targetType = "user" })
            }
        }
    } | ConvertTo-Json -Depth 6

    if ($PSCmdlet.ShouldProcess("partner $PartnerTenantId", "Turn on M365 Collaboration trust for all users")) {
        Invoke-Graph PATCH $graphBase $body | Out-Null
        Write-Host "Layer 2: M365 Collaboration trust turned on." -ForegroundColor Green
    } else {
        Write-Host "Layer 2: skipped, not changed. Capabilities have no effect until it's on." -ForegroundColor Yellow
    }
}

# --- Layer 3: grant the capabilities -------------------------------------------------------

$existingCaps = (Invoke-Graph GET "$graphBase/m365Capabilities").value

foreach ($cap in $Capability | Select-Object -Unique) {
    $odataType = "#microsoft.graph.$cap"
    $existing  = $existingCaps | Where-Object { $_.'@odata.type' -eq $odataType }

    if ($existing) {
        Write-Host "Layer 3: already configured, no change ($(Format-Capability $existing))." -ForegroundColor Green
        continue
    }

    # All users. Microsoft's guide uses resourceType "group" for Calendar Sharing, "user" for the rest.
    $resourceType = if ($cap -like 'crossTenantCalendarSharing*') { "group" } else { "user" }

    $body = @{
        "@odata.type" = $odataType
        inboundAccess = @{
            isAllowed      = $true
            resourceScopes = @{
                included = @(@{ resourceId = "All"; resourceType = $resourceType })
                excluded = @()
            }
        }
    } | ConvertTo-Json -Depth 6

    if ($PSCmdlet.ShouldProcess("partner $PartnerTenantId", "Grant $cap (all users)")) {
        Invoke-Graph POST "$graphBase/m365Capabilities" $body | Out-Null
        Write-Host "Layer 3: granted $cap to partner (all users)." -ForegroundColor Green
    } else {
        Write-Host "Layer 3: skipped $cap, not changed." -ForegroundColor Yellow
    }
}

# --- Show the result -----------------------------------------------------------------------

$partner = Invoke-Graph GET $graphBase
$caps    = (Invoke-Graph GET "$graphBase/m365Capabilities").value

$collab = $partner.m365CollaborationInbound.users
$collabText = if ($collab.accessType) {
    "$($collab.accessType) for $(@($collab.targets | ForEach-Object { if ($_.target -eq 'AllUsers') { 'all users' } else { $_.target } }) -join ', ')"
} else { "not set on this partner (inherits the default policy)" }

Write-Host "`nPartner $PartnerTenantId, as configured in tenant $TenantId" -ForegroundColor Cyan
Write-Host "  M365 Collaboration trust: $collabText"
if ($caps) {
    foreach ($c in $caps) { Write-Host "  Capability: $(Format-Capability $c)" }
} else {
    Write-Host "  Capabilities: none"
}

# Raw Graph responses, for troubleshooting: run with -Verbose
Write-Verbose ("m365CollaborationInbound:`n" + ($partner.m365CollaborationInbound | ConvertTo-Json -Depth 6))
Write-Verbose ("m365Capabilities:`n" + ($caps | ConvertTo-Json -Depth 6))

Write-Host "`nNext: the partner's admin runs this in their tenant with $TenantId as the partner, then test both directions (see the runbook's validation step)." -ForegroundColor Cyan
