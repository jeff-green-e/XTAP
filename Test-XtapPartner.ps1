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

    Requires the Microsoft.Graph.Authentication module. Signs in with Connect-MgGraph, the
    same way as Enable-XtapPartner.ps1 (keep the two sign-in blocks in step). If this window
    is already signed in to the same tenant, for example by Enable-XtapPartner.ps1, that
    sign-in is reused. Otherwise it asks for read-only permissions: a Global Administrator
    can approve them directly; a Global Reader or Security Reader can run it once an admin
    has approved them (Policy.Read.All needs admin consent), otherwise sign-in shows
    "Need admin approval".

.PARAMETER TenantId
    The tenant to check.

.PARAMETER PartnerTenantId
    One partner to check. If omitted, every partner entry in the tenant is checked.

.PARAMETER ExpectedCapability
    Capabilities this partner should have. Any that are missing are reported as FAIL.
    Only meaningful with -PartnerTenantId.

.PARAMETER CsvPath
    Also write the results to this CSV file (e.g. to attach to a change ticket).
    Columns: PartnerTenantId, PartnerName, Check, Status (PASS/WARN/FAIL/INFO), Detail.

.PARAMETER UseDeviceCode
    Sign in with a device code instead of an account picker or browser window.

.EXAMPLE
    # Every partner in the tenant
    .\Test-XtapPartner.ps1 -TenantId <your-tenant-id>

.EXAMPLE
    # One partner, and fail if Free/Busy basic or all MailTips isn't granted
    .\Test-XtapPartner.ps1 -TenantId <your-tenant-id> -PartnerTenantId <partner-tenant-id> `
        -ExpectedCapability crossTenantCalendarAvailabilityBasic, crossTenantMailTipsAll -CsvPath .\xtap-check.csv

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

    [switch] $UseDeviceCode
)

$ErrorActionPreference = 'Stop'

if ($ExpectedCapability -and -not $PartnerTenantId) {
    throw "-ExpectedCapability needs -PartnerTenantId (different partners usually get different capabilities)."
}
if ($PartnerTenantId -and $PartnerTenantId -eq $TenantId) {
    throw "TenantId and PartnerTenantId are the same. PartnerTenantId must be the OTHER tenant."
}

$policyBase = "https://graph.microsoft.com/beta/policies/crossTenantAccessPolicy"

function Get-StatusCode($errorRecord) {
    try { return [int]$errorRecord.Exception.Response.StatusCode } catch { return $null }
}

function Invoke-Graph([string] $Uri) {
    Invoke-MgGraphRequest -Method GET -Uri $Uri -OutputType PSObject
}

# --- Sign in (Connect-MgGraph) -------------------------------------------------------------

if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
    throw ("The Microsoft.Graph.Authentication module isn't installed. Install it with:`n" +
           "  Install-Module Microsoft.Graph.Authentication -Scope CurrentUser`nthen run this again.")
}
Import-Module Microsoft.Graph.Authentication

# Read-only scopes; an existing sign-in with the enable script's read/write scopes is also enough
# (partner names then may not resolve, which is only cosmetic).
$scopes   = @('Policy.Read.All', 'CrossTenantInformation.ReadBasic.All')
$writeSet = @('Policy.ReadWrite.CrossTenantAccess', 'Policy.ReadWrite.CrossTenantCapability')
$context  = Get-MgContext
$hasAll   = { param($need) -not ($need | Where-Object { $context.Scopes -notcontains $_ }) }
$reuse    = $context -and $context.TenantId -eq "$TenantId" -and
            ((& $hasAll $scopes) -or (& $hasAll $writeSet))

if (-not $reuse) {
    Write-Host "Sign in with an account that can read policies in tenant $TenantId. If asked for consent, leave 'Consent on behalf of your organization' unticked." -ForegroundColor Yellow
    $connect = @{ TenantId = "$TenantId"; Scopes = $scopes; NoWelcome = $true }
    if ($UseDeviceCode) { $connect.UseDeviceCode = $true }
    Connect-MgGraph @connect
    $context = Get-MgContext
}

if (-not $context -or $context.TenantId -ne "$TenantId") {
    throw ("Signed in to tenant $($context.TenantId), not $TenantId. Run Disconnect-MgGraph, then run " +
           "this again and sign in with an account from tenant $TenantId.")
}
Write-Host "Signed in as $($context.Account) to tenant $TenantId. Checking..." -ForegroundColor Green

# --- Helpers -------------------------------------------------------------------------------

function Invoke-GraphGetAll([string] $uri) {
    # Follows @odata.nextLink so large tenants aren't truncated
    $items = @()
    while ($uri) {
        $page  = Invoke-Graph $uri
        $items += $page.value
        $uri   = $page.'@odata.nextLink'
    }
    return $items
}

function Get-TenantName([guid] $id) {
    try {
        $info = Invoke-Graph "https://graph.microsoft.com/v1.0/tenantRelationships/findTenantInformationByTenantId(tenantId='$id')"
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

$default = Invoke-Graph "$policyBase/default"

# --- Which partners to check ---------------------------------------------------------------

if ($PartnerTenantId) {
    try {
        $partners = @(Invoke-Graph "$policyBase/partners/$PartnerTenantId")
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
