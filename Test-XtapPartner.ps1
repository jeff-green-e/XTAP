<#
.SYNOPSIS
    Read-only check of the XTAP configuration for one partner, or every partner, in a tenant.

.DESCRIPTION
    Reports, per partner, what THIS tenant grants that partner's users:
      - Partner entry     : the partner exists under Cross-tenant access settings (Layer 1)
      - M365 Collab trust : m365CollaborationInbound allows the partner's users (Layer 2)
      - Capabilities      : which M365 capabilities are granted, and to whom (Layer 3)
    With no -PartnerTenantId it also reports capabilities on the tenant-wide default policy,
    which apply to every Microsoft 365 organization without its own partner entry.

    Makes no changes. Needs only read permissions, so it can be run by reviewers or by a
    partner's admin. It checks one tenant: to check both directions of a pairing, the partner's
    admin runs it in their tenant too.

    It does not check old EWS-era configuration (Organization Relationships, Sharing Policies,
    Availability Address Spaces) and doesn't prove Free/Busy works for users. Use the Outlook
    tests in the runbook for that (02 Step 6 / 03 Step 5).

    The sign-in block is shared with Enable-XtapPartner.ps1 and the 02 runbook; keep
    them in step.

    Signs in with device-code flow as you, using Microsoft's first-party Graph Command Line
    Tools client. A Global Administrator can run it directly. Global Reader or Security
    Reader works once an admin has approved its read permissions (Policy.Read.All needs
    admin consent); otherwise sign-in shows "Need admin approval".

.PARAMETER TenantId
    The tenant to check.

.PARAMETER PartnerTenantId
    One partner to check. If omitted, every partner entry in the tenant is checked.

.PARAMETER ExpectedCapability
    Capabilities this partner should have. Any that are missing are reported as FAIL.
    Only meaningful with -PartnerTenantId.

.PARAMETER CsvPath
    Also write the results to this CSV file (e.g. to attach to a change ticket).

.PARAMETER PassThru
    Also return the results as objects, for filtering or further scripting.

.EXAMPLE
    # Every partner in the tenant
    .\Test-XtapPartner.ps1 -TenantId <your-tenant-id>

.EXAMPLE
    # One partner, and fail if Free/Busy basic or all MailTips isn't granted
    .\Test-XtapPartner.ps1 -TenantId <your-tenant-id> -PartnerTenantId <partner-tenant-id> `
        -ExpectedCapability crossTenantCalendarAvailabilityBasic, crossTenantMailTipsAll -CsvPath .\xtap-check.csv

.OUTPUTS
    With -PassThru, one object per check: PartnerTenantId, PartnerName, Check, Status (PASS/WARN/FAIL/INFO), Detail.

.LINK
    https://learn.microsoft.com/en-us/exchange/sharing/migrate-to-m365-xtap
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [guid] $TenantId,

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
    [string[]] $ExpectedCapability,

    [string] $CsvPath,

    [switch] $PassThru
)

$ErrorActionPreference = 'Stop'

if ($ExpectedCapability -and -not $PartnerTenantId) {
    throw "-ExpectedCapability needs -PartnerTenantId (different partners usually get different capabilities)."
}
if ($PartnerTenantId -and $PartnerTenantId -eq $TenantId) {
    throw "TenantId and PartnerTenantId are the same. PartnerTenantId must be the OTHER tenant."
}

$policyBase = "https://graph.microsoft.com/beta/policies/crossTenantAccessPolicy"

function Get-GraphErrorCode($errorRecord) {
    try { return ($errorRecord.ErrorDetails.Message | ConvertFrom-Json).error } catch { return $null }
}

function Get-StatusCode($errorRecord) {
    try { return [int]$errorRecord.Exception.Response.StatusCode } catch { return $null }
}

# --- Sign in (device-code flow) ------------------------------------------------------------

$clientId = "14d82eec-204b-4c2f-b7e8-296a70dab67e"  # Microsoft Graph Command Line Tools (Microsoft first-party public client)
$scope    = "https://graph.microsoft.com/Policy.Read.All https://graph.microsoft.com/CrossTenantInformation.ReadBasic.All"

$deviceCode = Invoke-RestMethod -Method Post `
    -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/devicecode" `
    -Body @{ client_id = $clientId; scope = $scope }

Write-Host $deviceCode.message -ForegroundColor Yellow
Write-Host "Sign in with an account that can read policies in tenant $TenantId. Leave 'Consent on behalf of your organization' unticked." -ForegroundColor Yellow

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
Write-Host "Signed in. Checking..." -ForegroundColor Green

# --- Helpers -------------------------------------------------------------------------------

function Invoke-GraphGetAll([string] $uri) {
    # Follows @odata.nextLink so large tenants aren't truncated
    $items = @()
    while ($uri) {
        $page  = Invoke-RestMethod -Method Get -Uri $uri -Headers $headers
        $items += $page.value
        $uri   = $page.'@odata.nextLink'
    }
    return $items
}

function Get-TenantName([guid] $id) {
    try {
        $info = Invoke-RestMethod -Method Get -Headers $headers `
            -Uri "https://graph.microsoft.com/v1.0/tenantRelationships/findTenantInformationByTenantId(tenantId='$id')"
        return $info.displayName
    } catch {
        return ""   # name lookup is a convenience; don't fail the check over it
    }
}

$results = [System.Collections.Generic.List[object]]::new()

function Add-Result($partnerId, $partnerName, $check, $status, $detail) {
    $results.Add([pscustomobject]@{
        PartnerTenantId = "$partnerId"
        PartnerName     = $partnerName
        Check           = $check
        Status          = $status
        Detail          = $detail
    })
}

function Format-Scope($resourceScopes) {
    $inc = @($resourceScopes.included | Where-Object { $_.resourceId }) |
        ForEach-Object { if ($_.resourceId -eq 'All') { "all users" } else { "$($_.resourceType) $($_.resourceId)" } }
    $exc = @($resourceScopes.excluded | Where-Object { $_.resourceId }) |
        ForEach-Object { "$($_.resourceType) $($_.resourceId)" }
    $text = if ($inc) { $inc -join ", " } else { "nobody" }
    if ($exc) { $text += " (except $($exc -join ', '))" }
    return $text
}

# --- Tenant-wide defaults (partners inherit these where they have no setting of their own) --

$default = Invoke-RestMethod -Method Get -Uri "$policyBase/default" -Headers $headers

# --- Which partners to check ---------------------------------------------------------------

if ($PartnerTenantId) {
    try {
        $partners = @(Invoke-RestMethod -Method Get -Uri "$policyBase/partners/$PartnerTenantId" -Headers $headers)
    } catch {
        if ((Get-StatusCode $_) -ne 404) { throw }
        $partners = @()
        Add-Result $PartnerTenantId (Get-TenantName $PartnerTenantId) "Partner entry" "FAIL" `
            "Not found. Add the organization in Entra admin center > Identity > External Identities > Cross-tenant access settings > Organizational settings."
    }
} else {
    $partners = @(Invoke-GraphGetAll "$policyBase/partners")
    if (-not $partners) {
        Add-Result "" "" "Partner entry" "INFO" "This tenant has no partner entries."
    }
}

# --- Per-partner checks --------------------------------------------------------------------

foreach ($p in $partners) {
    $id   = $p.tenantId
    $name = Get-TenantName $id

    Add-Result $id $name "Partner entry" "PASS" "Exists."

    # Layer 2: M365 Collaboration trust
    $collab = $p.m365CollaborationInbound.users
    $collabSource = "partner setting"
    if (-not $collab.accessType) { $collab = $default.m365CollaborationInbound.users; $collabSource = "inherited from default" }

    $targets = @($collab.targets | ForEach-Object { $_.target })
    if ($collab.accessType -eq 'allowed' -and $targets -contains 'AllUsers') {
        if ($collabSource -eq 'partner setting') {
            Add-Result $id $name "M365 Collab trust" "PASS" "Allowed for all users."
        } else {
            Add-Result $id $name "M365 Collab trust" "WARN" "Allowed for all users, but only through the default policy. The runbooks set it on the partner so it doesn't change if the default does."
        }
    } elseif ($collab.accessType -eq 'allowed') {
        Add-Result $id $name "M365 Collab trust" "WARN" "Allowed only for: $($targets -join ', ') ($collabSource). Partner users outside that scope get nothing."
    } elseif ($collab.accessType -eq 'blocked') {
        Add-Result $id $name "M365 Collab trust" "FAIL" "Blocked ($collabSource). Capabilities have no effect until this is allowed."
    } else {
        Add-Result $id $name "M365 Collab trust" "FAIL" "Not configured. Run Enable-XtapPartner.ps1 or the runbook's Layer 2 step."
    }

    # Layer 3: capabilities
    try {
        $caps = @(Invoke-GraphGetAll "$policyBase/partners/$id/m365Capabilities")
    } catch {
        $code = Get-StatusCode $_
        Add-Result $id $name "Capabilities" "WARN" "Couldn't read capabilities (HTTP $code). Your account or consent may lack read access to M365 capabilities."
        continue
    }

    $granted = @()
    foreach ($c in $caps) {
        $capName = ($c.'@odata.type' -replace '^#?microsoft\.graph\.', '')
        if ($c.inboundAccess.isAllowed) {
            $granted += $capName
            Add-Result $id $name "Capability" "INFO" "$capName granted to $(Format-Scope $c.inboundAccess.resourceScopes)."
        } else {
            Add-Result $id $name "Capability" "INFO" "$capName present but not allowed (isAllowed = false)."
        }
    }

    if (-not $granted) {
        Add-Result $id $name "Capabilities" "FAIL" "No capabilities granted. The partner's users can't see anything in this tenant."
    }

    foreach ($want in $ExpectedCapability) {
        if ($granted -ccontains $want) {
            Add-Result $id $name "Expected capability" "PASS" "$want is granted."
        } else {
            Add-Result $id $name "Expected capability" "FAIL" "$want is not granted."
        }
    }
}

# --- Tenant-wide default capabilities (whole-tenant run only) ------------------------------

if (-not $PartnerTenantId) {
    try {
        $defaultCaps = @(Invoke-GraphGetAll "$policyBase/default/m365Capabilities")
        $allowed = @($defaultCaps | Where-Object { $_.inboundAccess.isAllowed })
        if ($allowed) {
            foreach ($c in $allowed) {
                $capName = ($c.'@odata.type' -replace '^#?microsoft\.graph\.', '')
                Add-Result "(default)" "All other M365 orgs" "Default capability" "WARN" `
                    "$capName granted to $(Format-Scope $c.inboundAccess.resourceScopes) for EVERY organization without its own partner entry. Confirm this is intended."
            }
        } else {
            Add-Result "(default)" "All other M365 orgs" "Default capability" "PASS" "No capabilities granted tenant-wide."
        }
    } catch {
        Add-Result "(default)" "All other M365 orgs" "Default capability" "WARN" "Couldn't read default capabilities (HTTP $(Get-StatusCode $_))."
    }
}

# --- Report --------------------------------------------------------------------------------

$colors = @{ PASS = 'Green'; WARN = 'Yellow'; FAIL = 'Red'; INFO = 'Gray' }

foreach ($group in ($results | Group-Object PartnerTenantId)) {
    $first = $group.Group[0]
    $label = if ($first.PartnerName) { "$($first.PartnerName) ($($first.PartnerTenantId))" } else { $first.PartnerTenantId }
    Write-Host "`n$label" -ForegroundColor Cyan
    foreach ($r in $group.Group) {
        Write-Host ("  [{0}] {1,-20} {2}" -f $r.Status, $r.Check, $r.Detail) -ForegroundColor $colors[$r.Status]
    }
}

$fails = @($results | Where-Object Status -eq 'FAIL').Count
$warns = @($results | Where-Object Status -eq 'WARN').Count
Write-Host "`n$fails FAIL, $warns WARN. This checks tenant $TenantId only; the partner's admin checks their side." -ForegroundColor Cyan

if ($CsvPath) {
    $results | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8
    Write-Host "Results written to $CsvPath" -ForegroundColor Cyan
}

if ($PassThru) { $results }
