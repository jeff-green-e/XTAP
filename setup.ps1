# Delegated auth via device-code flow: signs in as YOU (Global Admin), no app
# registration, certificate, or secret required.
$tenantId = ""
$clientId = "14d82eec-204b-4c2f-b7e8-296a70dab67e"  # Microsoft Graph Command Line Tools (Microsoft first-party public client)
$scope = "https://graph.microsoft.com/Policy.ReadWrite.CrossTenantAccess https://graph.microsoft.com/Policy.ReadWrite.CrossTenantCapability"

$deviceCodeResponse = Invoke-RestMethod -Method Post `
    -Uri "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/devicecode" `
    -Body @{ client_id = $clientId; scope = $scope }

Write-Host $deviceCodeResponse.message
# "To sign in, use a web browser to open https://microsoft.com/devicelogin
#  and enter the code XXXXXXXXX." Do that now, signing in as an account
#  with Global Administrator or Security Administrator in this tenant.

do {
    Start-Sleep -Seconds $deviceCodeResponse.interval
    try {
        $token = Invoke-RestMethod -Method Post `
            -Uri "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token" `
            -Body @{
                grant_type  = "urn:ietf:params:oauth:grant-type:device_code"
                client_id   = $clientId
                device_code = $deviceCodeResponse.device_code
            }
        break
    } catch {
        # authorization_pending: keep polling until you finish signing in
    }
} while ($true)

$headers = @{ Authorization = "Bearer $($token.access_token)" }
# Reuse $headers on every call in Steps 3 and 4


$partnerTenantId = ""  # the tenant ID of the partner you want to trust for M365 Collaboration inbound

# Enable M365 Collaboration inbound trust for a specific partner tenant
# Only MFA is trusted in this scenario; device compliance and hybrid Entra join are
# NOT accepted as substitutes, so both are explicitly false rather than omitted.
$body = @{
    inboundTrust = @{
        isMfaAccepted                       = $true
        isCompliantDeviceAccepted           = $false
        isHybridAzureADJoinedDeviceAccepted = $false
    }
} | ConvertTo-Json -Depth 6

Invoke-RestMethod -Method Patch `
    -Uri "https://graph.microsoft.com/beta/policies/crossTenantAccessPolicy/partners/$partnerTenantId" `
    -Headers $headers -ContentType "application/json" -Body $body
# Note: the exact property that flips on "m365CollaborationInbound" specifically is still
# moving on the beta surface; confirm the current field name against Microsoft Learn's
# migration doc before running this against a production tenant.


$body = @{
    "@odata.type"  = "microsoft.graph.crossTenantCalendarAvailabilityBasic"
    inboundAccess  = @{
        isAllowed      = $true
        resourceScopes = @{
            included = @(@{ resourceId = "All"; resourceType = "user" })
            excluded = @()
        }
    }
} | ConvertTo-Json -Depth 6

Invoke-RestMethod -Method Post `
    -Uri "https://graph.microsoft.com/beta/policies/crossTenantAccessPolicy/partners/$partnerTenantId/m365Capabilities" `
    -Headers $headers -ContentType "application/json" -Body $body
