<#
.SYNOPSIS
    Turns on M365 Collaboration trust (Layer 2) and grants M365 capabilities (Layer 3)
    to a partner tenant, so the partner's users can see this tenant's Free/Busy, MailTips,
    or shared calendars.

.DESCRIPTION
    Automates the PowerShell steps of the runbooks in this repo:
      - 02-migrate-existing-sharing.md, Steps 2 to 4 (moving existing sharing off EWS)
      - 03-set-up-new-sharing.md,       Steps 2 to 4 (sharing with a new partner)
    Follow the runbook; this script doesn't replace it.
    The manual PowerShell snippets in 02 and 03 mirror this script. If you change the
    Graph calls, sign-in, or safety checks here, update those snippets too.

    What it does NOT do:
      - Create or change the partner's cross-tenant access settings (Layer 1), including
        trust settings. Those are verified or added in the Entra admin center first
        (02 Step 3 / 03 Step 1). If the partner entry doesn't exist, the script stops.
      - Configure the partner's side. Sharing is inbound only: running this in tenant A
        lets B's users see A. B's admin runs it in B, with A as the partner.
      - Disable old EWS-era configuration (see 02).
      - Limit a grant to a security group. It always grants to all users; for group
        scoping, use the manual capability step in the runbook.

    Signs in with device-code flow as you (Global Administrator), using Microsoft's
    first-party Graph Command Line Tools client. No app registration or secret.
    Re-running is safe: settings that already exist are left alone, so you can run it
    again later to add another capability.

.PARAMETER TenantId
    Your tenant: the one whose data the partner will be allowed to see.

.PARAMETER PartnerTenantId
    The partner tenant being granted access.

.PARAMETER Capability
    One or more capabilities to grant. Default: crossTenantCalendarAvailabilityBasic
    (free/busy times only, the Scheduling Assistant case). Names come from the Microsoft
    Learn migration guide and are case-sensitive.

.EXAMPLE
    # Free/busy times only (the default)
    .\Enable-XtapPartner.ps1 -TenantId <your-tenant-id> -PartnerTenantId <partner-tenant-id>

.EXAMPLE
    # Free/busy and all MailTips, in one sign-in
    .\Enable-XtapPartner.ps1 -TenantId <your-tenant-id> -PartnerTenantId <partner-tenant-id> `
        -Capability crossTenantCalendarAvailabilityBasic, crossTenantMailTipsAll

.EXAMPLE
    # Also print the raw Graph responses at the end, for troubleshooting
    .\Enable-XtapPartner.ps1 -TenantId <id> -PartnerTenantId <id> -Verbose

.EXAMPLE
    # Show what would change without changing anything
    .\Enable-XtapPartner.ps1 -TenantId <id> -PartnerTenantId <id> `
        -Capability crossTenantMailTipsAll -WhatIf

.LINK
    https://learn.microsoft.com/en-us/exchange/sharing/migrate-to-m365-xtap
#>
[CmdletBinding(SupportsShouldProcess)]
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
    [string[]] $Capability = 'crossTenantCalendarAvailabilityBasic'
)

$ErrorActionPreference = 'Stop'

if ($TenantId -eq $PartnerTenantId) {
    throw "TenantId and PartnerTenantId are the same. PartnerTenantId must be the OTHER tenant."
}

$graphBase  = "https://graph.microsoft.com/beta/policies/crossTenantAccessPolicy/partners/$PartnerTenantId"
$jsonParams = @{ ContentType = "application/json" }

function Get-GraphErrorCode($errorRecord) {
    try { return ($errorRecord.ErrorDetails.Message | ConvertFrom-Json).error } catch { return $null }
}

function Format-Capability($c) {
    # One line per capability, e.g. "crossTenantCalendarAvailabilityBasic: allowed for all users"
    $name = $c.'@odata.type' -replace '^#?microsoft\.graph\.', ''
    if (-not $c.inboundAccess.isAllowed) { return "${name}: present but not allowed" }
    $who = @($c.inboundAccess.resourceScopes.included | Where-Object { $_.resourceId }) |
        ForEach-Object { if ($_.resourceId -eq 'All') { "all users" } else { "$($_.resourceType) $($_.resourceId)" } }
    return "${name}: allowed for $(if ($who) { $who -join ', ' } else { 'nobody' })"
}

# --- Sign in (device-code flow) ------------------------------------------------------------

$clientId = "14d82eec-204b-4c2f-b7e8-296a70dab67e"  # Microsoft Graph Command Line Tools (Microsoft first-party public client)
$scope    = "https://graph.microsoft.com/Policy.ReadWrite.CrossTenantAccess https://graph.microsoft.com/Policy.ReadWrite.CrossTenantCapability"

$deviceCode = Invoke-RestMethod -Method Post `
    -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/devicecode" `
    -Body @{ client_id = $clientId; scope = $scope }

Write-Host $deviceCode.message -ForegroundColor Yellow
Write-Host "Sign in as a Global Administrator of tenant $TenantId." -ForegroundColor Yellow

$interval = [int]$deviceCode.interval
$deadline = (Get-Date).AddSeconds([int]$deviceCode.expires_in)
$token    = $null

while (-not $token) {
    if ((Get-Date) -gt $deadline) { throw "The sign-in code expired. Run the script again." }
    Start-Sleep -Seconds $interval
    try {
        $token = Invoke-RestMethod -Method Post `
            -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
            -Body @{
                grant_type  = "urn:ietf:params:oauth:grant-type:device_code"
                client_id   = $clientId
                device_code = $deviceCode.device_code
            }
    } catch {
        $err = $_
        switch (Get-GraphErrorCode $err) {
            'authorization_pending' { }                  # not signed in yet; keep waiting
            'slow_down'             { $interval += 5 }   # server asked us to poll less often
            default                 { throw $err }       # declined, expired, wrong tenant, etc.
        }
    }
}

$headers = @{ Authorization = "Bearer $($token.access_token)" }
Write-Host "Signed in." -ForegroundColor Green

# --- Check the partner entry exists (Layer 1 is managed in the portal) ---------------------

try {
    $partner = Invoke-RestMethod -Method Get -Uri $graphBase -Headers $headers
} catch {
    if ([int]$_.Exception.Response.StatusCode -eq 404) {
        throw ("No cross-tenant access entry for partner $PartnerTenantId. Add the organization in " +
               "Entra admin center > Identity > External Identities > Cross-tenant access settings > " +
               "Organizational settings, verify its trust settings, then run this again.")
    }
    throw
}

# --- Layer 2: M365 Collaboration trust -----------------------------------------------------

$current   = $partner.m365CollaborationInbound.users
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
        Invoke-RestMethod -Method Patch -Uri $graphBase -Headers $headers -Body $body @jsonParams | Out-Null
        Write-Host "Layer 2: M365 Collaboration trust turned on." -ForegroundColor Green
    }
}

# --- Layer 3: grant the capabilities -------------------------------------------------------

$existingCaps = (Invoke-RestMethod -Method Get -Uri "$graphBase/m365Capabilities" -Headers $headers).value

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
        Invoke-RestMethod -Method Post -Uri "$graphBase/m365Capabilities" -Headers $headers -Body $body @jsonParams | Out-Null
        Write-Host "Layer 3: granted $cap to partner (all users)." -ForegroundColor Green
    }
}

# --- Show the result -----------------------------------------------------------------------

$partner = Invoke-RestMethod -Method Get -Uri $graphBase -Headers $headers
$caps    = (Invoke-RestMethod -Method Get -Uri "$graphBase/m365Capabilities" -Headers $headers).value

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
