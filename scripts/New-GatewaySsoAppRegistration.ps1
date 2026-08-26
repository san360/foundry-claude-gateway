<#
.SYNOPSIS
    Creates (or updates) the Microsoft Entra ID app registration that backs
    Claude Desktop's "Interactive sign-in" credential kind against the API
    Management AI gateway.

.DESCRIPTION
    This is the app registration for SCENARIO C - gateway interactive sign-in.
    It is deliberately separate from New-FoundryAppRegistration.ps1, which
    registers the DIRECT path app and is unchanged.

    Why a second registration exists at all
    ---------------------------------------
    The direct-path app has to request 'user_impersonation' on Microsoft's
    Cognitive Services API. You do not own that API, so you cannot pre-authorize
    it, and a tenant with restricted consent will stop every user at
    'Need admin approval'. That is the wall this repo hit.

    The gateway path moves the token audience onto an application YOU own. The
    user's token is only ever presented to API Management; API Management then
    calls Foundry with its own managed identity. So the user's token needs no
    Foundry permission, no Microsoft first-party scope, and - because you own
    both ends - no consent prompt at all.

    What it configures, and why each piece matters:

      * Public client + http://127.0.0.1/callback
                                     - Claude Desktop binds an ephemeral loopback
                                       port. Entra wildcards the loopback PORT but
                                       NOT the path, so /callback is mandatory or
                                       sign-in fails with AADSTS50011. Must sit
                                       under the 'Mobile and desktop applications'
                                       platform specifically.
      * Broker redirect URIs         - required by -AuthFlow broker (WAM on
                                       Windows, Company Portal on macOS), which is
                                       what satisfies Conditional Access policies
                                       demanding a compliant device.
      * api://{appId} + Gateway.Access scope
                                     - the audience API Management validates.
                                       Declared type 'User' so it never demands an
                                       admin.
      * preAuthorizedApplications    - the load-bearing part. A pre-authorized
                                       client skips the consent framework
                                       entirely: no admin consent AND no user
                                       consent prompt. Without this, a tenant on
                                       'microsoft-user-default-low' blocks the
                                       scope, because a custom scope carries no
                                       low-impact classification.
      * requiredResourceAccess -> self
                                     - surfaces the scope under API permissions.
                                       Claude Desktop's docs are explicit that
                                       omitting it fails with AADSTS65001.
      * groupMembershipClaims        - 'ApplicationGroup' emits ONLY groups
                                       assigned to this app. Do not use
                                       'SecurityGroup' here: a JWT caps at 200
                                       groups and then drops the claim entirely in
                                       favour of _claim_names, which would deny
                                       every user in a large tenant.

    Deliberately NOT configured
    ---------------------------
    'Assignment required' is left OFF. Microsoft's documentation is explicit:
    "Applications that require users to be assigned to the application must have
    their permissions consented by an administrator." Turning it on would trade
    away the entire no-admin-consent property. Authorization is enforced at the
    gateway instead, via the groups claim.

.PARAMETER DisplayName
    Name of the app registration. Also the lookup key for idempotency.

.PARAMETER AllowedGroup
    Display name or object ID of a security group permitted to use the gateway.
    The group is assigned to the enterprise application so that it appears in the
    'ApplicationGroup' groups claim. Repeatable.

    Assigning a group (rather than individual users) to an application requires
    Microsoft Entra ID P1 or P2.

.PARAMETER PreAuthorizeAzureCli
    Also pre-authorize the Azure CLI's well-known client ID for the scope. This
    lets 'az account get-access-token --scope api://<appId>/Gateway.Access'
    mint a real token non-interactively, which is how Test-GatewaySso.ps1
    verifies the policy without driving the desktop UI. On by default.

.EXAMPLE
    ./scripts/New-GatewaySsoAppRegistration.ps1

.EXAMPLE
    ./scripts/New-GatewaySsoAppRegistration.ps1 -AllowedGroup 'Claude Gateway Users'

.OUTPUTS
    Writes the resulting client ID, application ID URI, scope and tenant to the
    console, and returns them as an object for scripting.
#>
[CmdletBinding()]
param(
    [string]$DisplayName = 'Claude Desktop - AI Gateway SSO',

    [string[]]$AllowedGroup = @(),

    [bool]$PreAuthorizeAzureCli = $true
)

$ErrorActionPreference = 'Stop'

# Azure CLI's first-party client ID. Already consented in every tenant, which
# makes it a convenient stand-in for Claude Desktop when testing.
$azureCliAppId = '04b07795-8ddb-461a-bbee-02f9e1bf7b46'

$scopeName = 'Gateway.Access'

function Invoke-Az {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $out = & az @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "az $($Arguments -join ' ') failed:`n$($out -join "`n")"
    }
    return $out
}

function Invoke-AzQuiet {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $prior = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & az @Arguments 2>&1 | Out-Null }
    finally { $ErrorActionPreference = $prior }
    return ($LASTEXITCODE -eq 0)
}

function Invoke-Graph {
    param(
        [Parameter(Mandatory)][ValidateSet('get', 'post', 'patch')][string]$Method,
        [Parameter(Mandatory)][string]$Uri,
        $Body
    )
    $azArgs = @('rest', '--method', $Method, '--uri', $Uri)
    $file = $null
    if ($null -ne $Body) {
        $file = Join-Path ([IO.Path]::GetTempPath()) "gw-sso-$PID-$(Get-Random).json"
        # Graph rejects a UTF-8 BOM, which Set-Content -Encoding utf8 emits on
        # Windows PowerShell.
        [IO.File]::WriteAllText($file, ($Body | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding($false)))
        $azArgs += @('--headers', 'Content-Type=application/json', '--body', "@$file")
    }
    try { return Invoke-Az $azArgs }
    finally { if ($file) { Remove-Item $file -ErrorAction SilentlyContinue } }
}

$tenantId = (Invoke-Az @('account', 'show', '--query', 'tenantId', '-o', 'tsv')) | Select-Object -Last 1
$upn = (Invoke-Az @('account', 'show', '--query', 'user.name', '-o', 'tsv')) | Select-Object -Last 1

Write-Host ''
Write-Host 'Entra ID app registration for Claude Desktop gateway interactive sign-in'
Write-Host ''
Write-Host ('{0,-16} {1}' -f 'Tenant:', $tenantId)
Write-Host ('{0,-16} {1}' -f 'Signed in as:', $upn)
Write-Host ('{0,-16} {1}' -f 'App name:', $DisplayName)
Write-Host ''

# --- find or create -------------------------------------------------------

$existing = ((Invoke-Az @(
    'ad', 'app', 'list',
    '--filter', "displayName eq '$DisplayName'",
    '--query', '[0].{appId:appId,objectId:id}', '-o', 'json'
)) -join '') | ConvertFrom-Json

if ($existing -and $existing.appId) {
    $appId = $existing.appId
    $objectId = $existing.objectId
    Write-Host "Reusing existing registration $appId" -ForegroundColor DarkGray
}
else {
    $new = ((Invoke-Az @(
        'ad', 'app', 'create',
        '--display-name', $DisplayName,
        '--sign-in-audience', 'AzureADMyOrg',
        '--query', '{appId:appId,objectId:id}', '-o', 'json'
    )) -join '') | ConvertFrom-Json
    $appId = $new.appId
    $objectId = $new.objectId
    Write-Host "Created registration $appId" -ForegroundColor Green

    # Entra replicates a brand-new application asynchronously; a PATCH issued
    # immediately can 404. Poll until the object is readable.
    for ($i = 0; $i -lt 12; $i++) {
        if (Invoke-AzQuiet @('ad', 'app', 'show', '--id', $appId, '--query', 'id', '-o', 'tsv')) { break }
        Start-Sleep -Seconds 5
    }
}

# --- scope identity -------------------------------------------------------

# Reuse the existing scope GUID when re-running. Minting a fresh one would
# orphan every consent grant and pre-authorization that references the old ID.
$current = ((Invoke-Graph -Method get -Uri "https://graph.microsoft.com/v1.0/applications/$objectId") -join '') | ConvertFrom-Json
$scopeId = $null
if ($current.api -and $current.api.oauth2PermissionScopes) {
    $scopeId = ($current.api.oauth2PermissionScopes | Where-Object { $_.value -eq $scopeName } | Select-Object -First 1).id
}
if (-not $scopeId) { $scopeId = [guid]::NewGuid().ToString() }

$identifierUri = "api://$appId"

# --- PATCH 1: identity, platform and the exposed scope --------------------
#
# This has to happen before pre-authorization. Graph validates
# preAuthorizedApplications against the scopes that already exist on the object,
# so referencing a scope in the same request that creates it fails with
# "Permission Id that cannot be found in the AppPermissions sets".

$scopeDefinition = [ordered]@{
    id                      = $scopeId
    value                   = $scopeName
    # 'User' means this scope never demands an administrator. It is not what
    # removes the prompt - pre-authorization does that - but it keeps the
    # fallback path open if pre-auth is ever removed.
    type                    = 'User'
    isEnabled               = $true
    adminConsentDisplayName = 'Call Claude models through the AI gateway'
    adminConsentDescription = 'Allows the signed-in user to call Claude models in Microsoft Foundry through the API Management AI gateway.'
    userConsentDisplayName  = 'Call Claude models through the AI gateway'
    userConsentDescription  = 'Allows this app to call Claude models on your behalf through your organization''s AI gateway.'
}

$stage1 = [ordered]@{
    identifierUris         = @($identifierUri)
    isFallbackPublicClient = $true
    # ApplicationGroup, not SecurityGroup. See the .DESCRIPTION note about the
    # 200-group JWT ceiling.
    groupMembershipClaims  = 'ApplicationGroup'
    publicClient           = [ordered]@{
        redirectUris = @(
            'http://127.0.0.1/callback'
            "ms-appx-web://Microsoft.AAD.BrokerPlugin/$appId"
            'msauth.com.anthropic.claudefordesktop://auth'
        )
    }
    api                    = [ordered]@{
        # v2 keeps the issuer at /v2.0 and puts the bare app ID GUID in 'aud'.
        requestedAccessTokenVersion = 2
        oauth2PermissionScopes      = @($scopeDefinition)
    }
}

Invoke-Graph -Method patch -Uri "https://graph.microsoft.com/v1.0/applications/$objectId" -Body $stage1 | Out-Null
Write-Host 'Configured public client, loopback + broker redirect URIs and the exposed API' -ForegroundColor Green

# --- PATCH 2: pre-authorization and self-referencing permission -----------

$preAuthorized = @(
    # The app is its own client: Claude Desktop signs in with this same client
    # ID and asks for this app's scope. Pre-authorizing it against itself is
    # what removes the consent prompt.
    [ordered]@{ appId = $appId; delegatedPermissionIds = @($scopeId) }
)
if ($PreAuthorizeAzureCli) {
    $preAuthorized += [ordered]@{ appId = $azureCliAppId; delegatedPermissionIds = @($scopeId) }
}

# 'api' is replaced wholesale by a PATCH, so the scope has to be repeated here
# or it would be deleted.
$stage2 = [ordered]@{
    api                    = [ordered]@{
        requestedAccessTokenVersion = 2
        oauth2PermissionScopes      = @($scopeDefinition)
        preAuthorizedApplications   = $preAuthorized
    }
    requiredResourceAccess = @(
        # Pointing the app at its own scope is what surfaces it under API
        # permissions. Claude Desktop's docs call this out: without it Entra
        # rejects the sign-in with AADSTS65001.
        [ordered]@{
            resourceAppId  = $appId
            resourceAccess = @([ordered]@{ id = $scopeId; type = 'Scope' })
        }
    )
}

Invoke-Graph -Method patch -Uri "https://graph.microsoft.com/v1.0/applications/$objectId" -Body $stage2 | Out-Null
Write-Host 'Pre-authorized the client so no consent prompt is raised' -ForegroundColor Green

# A service principal is what makes the app assignable and visible under
# Enterprise applications. Harmless if it already exists.
Invoke-AzQuiet @('ad', 'sp', 'create', '--id', $appId) | Out-Null
$spId = (Invoke-Az @('ad', 'sp', 'show', '--id', $appId, '--query', 'id', '-o', 'tsv')) | Select-Object -Last 1

# --- group assignment -----------------------------------------------------

$assignedGroups = @()
foreach ($g in $AllowedGroup) {
    # 'id eq' and 'displayName eq' cannot be combined in one filter: the CLI
    # validates a non-GUID value against the id field and refuses it outright
    # with "Invalid object identifier". Pick the lookup by shape instead.
    if ($g -match '^[0-9a-fA-F-]{36}$') {
        $groupJson = Invoke-Az @('ad', 'group', 'show', '--group', $g, '--query', '{id:id,name:displayName}', '-o', 'json')
    }
    else {
        $groupJson = Invoke-Az @(
            'ad', 'group', 'list',
            '--filter', "displayName eq '$g'",
            '--query', '[0].{id:id,name:displayName}', '-o', 'json'
        )
    }
    $group = ($groupJson -join '') | ConvertFrom-Json

    if (-not $group -or -not $group.id) {
        Write-Host "  Group '$g' not found - skipping" -ForegroundColor Yellow
        continue
    }

    # appRoleId all-zeros is the 'default access' pseudo-role. It is the correct
    # value when the app exposes no app roles but you still want the group
    # assigned so it lands in the ApplicationGroup claim.
    $assignBody = [ordered]@{
        principalId = $group.id
        resourceId  = $spId
        appRoleId   = '00000000-0000-0000-0000-000000000000'
    }
    $ok = $true
    try {
        Invoke-Graph -Method post `
            -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$spId/appRoleAssignedTo" `
            -Body $assignBody | Out-Null
    }
    catch {
        # A duplicate assignment is success as far as this script is concerned.
        if ("$_" -notmatch 'already exists|Permission being assigned already exists') {
            Write-Host "  Could not assign '$($group.name)': $_" -ForegroundColor Yellow
            $ok = $false
        }
    }
    if ($ok) {
        Write-Host "  Assigned group '$($group.name)' ($($group.id))" -ForegroundColor Green
        $assignedGroups += $group
    }
}

# --- report ---------------------------------------------------------------

$result = [ordered]@{
    tenantId      = $tenantId
    clientId      = $appId
    identifierUri = $identifierUri
    scope         = "$identifierUri/$scopeName"
    issuer        = "https://login.microsoftonline.com/$tenantId/v2.0"
    allowedGroups = @($assignedGroups | ForEach-Object { $_.id })
}

Write-Host ''
Write-Host ('=' * 78)
Write-Host ' GATEWAY SSO APP REGISTRATION'
Write-Host ('=' * 78)
Write-Host ('{0,-18} {1}' -f 'Client ID:', $result.clientId)
Write-Host ('{0,-18} {1}' -f 'App ID URI:', $result.identifierUri)
Write-Host ('{0,-18} {1}' -f 'Scope:', $result.scope)
Write-Host ('{0,-18} {1}' -f 'Issuer:', $result.issuer)
if ($result.allowedGroups.Count) {
    Write-Host ('{0,-18} {1}' -f 'Allowed groups:', ($result.allowedGroups -join ', '))
}
else {
    Write-Host ('{0,-18} {1}' -f 'Allowed groups:', '(none - gateway will not enforce a groups claim)')
}
Write-Host ''
Write-Host 'Claude Desktop -> Developer -> Configure Third-Party Inference -> Gateway:'
Write-Host '  Credential kind          Interactive sign-in'
Write-Host "  Client ID                $($result.clientId)"
Write-Host "  Issuer URL               $($result.issuer)"
Write-Host '  Bearer token             Access token'
Write-Host "  Scopes                   openid profile email $($result.scope)"
Write-Host '  Redirect port            (leave empty)'
Write-Host ''

[pscustomobject]$result
