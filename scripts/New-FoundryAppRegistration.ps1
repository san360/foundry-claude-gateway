<#
.SYNOPSIS
    Creates (or updates) the Microsoft Entra ID app registration that Claude
    Desktop and Claude Code use for interactive sign-in to Claude models in
    Microsoft Foundry.

.DESCRIPTION
    The Foundry provider in Claude Desktop signs the user in with MSAL as a
    PUBLIC CLIENT - there is no client secret anywhere, on disk or in .env.
    The app registration produced here is what the 'Entra ID client ID' field
    in the Foundry settings pane expects.

    The script is idempotent: run it repeatedly and it converges the same
    application object rather than creating duplicates.

    What it configures, and why each piece matters:

      * Allow public client flows      - required by the device-code flow.
      * http://127.0.0.1/callback      - required by the browser (PKCE) flow.
                                         Entra wildcards the loopback PORT but
                                         NOT the path, so the /callback suffix
                                         is mandatory or sign-in fails with
                                         AADSTS50011.
      * ms-appx-web://Microsoft.AAD.BrokerPlugin/{clientId}
        msauth.com.anthropic.claudefordesktop://auth
                                       - required by the broker flow on Windows
                                         and macOS respectively.
      * Cognitive Services user_impersonation (delegated)
                                       - the scope that lets the signed-in user
                                         call the Foundry data plane. Nominally
                                         user-consentable, but a tenant that
                                         disables self-service consent overrides
                                         that and requires an admin grant. See
                                         -GrantAdminConsent.

    Registering all three redirect URIs costs nothing and lets you switch
    -AuthFlow later without touching Entra again.

.PARAMETER DisplayName
    Name of the app registration. Also the lookup key for idempotency.

.PARAMETER SignInAudience
    AzureADMyOrg (default) restricts sign-in to this tenant only.

.PARAMETER GrantAdminConsent
    Consent the delegated scope for the whole tenant. Requires Privileged Role
    Administrator or Global Administrator, and is skipped with a warning if you
    lack the permission.

    Treat this as REQUIRED unless you know the tenant allows self-service
    consent. Where an admin has set 'Do not allow user consent', users cannot
    approve the scope themselves and sign-in fails with 'Need admin approval'
    no matter how user-consentable the scope nominally is.

.EXAMPLE
    ./scripts/New-FoundryAppRegistration.ps1
    ./scripts/New-FoundryAppRegistration.ps1 -GrantAdminConsent
#>
[CmdletBinding()]
param(
    [string]$DisplayName = 'Claude Desktop - Microsoft Foundry',

    [ValidateSet('AzureADMyOrg', 'AzureADMultipleOrgs')]
    [string]$SignInAudience = 'AzureADMyOrg',

    [switch]$GrantAdminConsent
)

$ErrorActionPreference = 'Stop'

# Well-known, tenant-independent identifiers for the Microsoft Cognitive
# Services resource application and its delegated user_impersonation scope.
$cognitiveServicesAppId = '7d312290-28c8-473c-a0ed-8e53749b6d6d'
$userImpersonationScope = '5f1e8914-a52b-429f-9324-91b92b81adaf'

function Invoke-Az {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $out = & az @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "az $($Arguments -join ' ') failed:`n$($out -join "`n")"
    }
    return $out
}

function Invoke-AzQuiet {
    # Native commands write progress and warnings to stderr, which PowerShell
    # turns into a terminating error under $ErrorActionPreference = 'Stop'.
    # These calls are best-effort, so judge them by the exit code instead.
    param([Parameter(Mandatory)][string[]]$Arguments)
    $prior = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & az @Arguments 2>&1 | Out-Null }
    finally { $ErrorActionPreference = $prior }
    return ($LASTEXITCODE -eq 0)
}

$tenantId = (Invoke-Az @('account', 'show', '--query', 'tenantId', '-o', 'tsv')) | Select-Object -Last 1
$upn = (Invoke-Az @('account', 'show', '--query', 'user.name', '-o', 'tsv')) | Select-Object -Last 1

Write-Host ''
Write-Host 'Entra ID app registration for Claude on Microsoft Foundry'
Write-Host ''
Write-Host ('{0,-16} {1}' -f 'Tenant:', $tenantId)
Write-Host ('{0,-16} {1}' -f 'Signed in as:', $upn)
Write-Host ('{0,-16} {1}' -f 'App name:', $DisplayName)
Write-Host ''

# --- find or create -------------------------------------------------------

$existing = Invoke-Az @(
    'ad', 'app', 'list',
    '--filter', "displayName eq '$DisplayName'",
    '--query', '[0].{appId:appId,objectId:id}', '-o', 'json'
)
$app = ($existing -join '') | ConvertFrom-Json

if ($app -and $app.appId) {
    $appId = $app.appId
    $objectId = $app.objectId
    Write-Host "Reusing existing registration $appId" -ForegroundColor DarkGray
}
else {
    $created = Invoke-Az @(
        'ad', 'app', 'create',
        '--display-name', $DisplayName,
        '--sign-in-audience', $SignInAudience,
        '--query', '{appId:appId,objectId:id}', '-o', 'json'
    )
    $new = ($created -join '') | ConvertFrom-Json
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

# --- redirect URIs, public client flag and API permission -----------------

# One PATCH against Microsoft Graph sets everything the three sign-in flows
# need. Doing it as a single graph call keeps the object consistent even if the
# script is interrupted, and avoids the CLI's piecemeal --set semantics.
$graphBody = [ordered]@{
    isFallbackPublicClient = $true
    publicClient           = [ordered]@{
        redirectUris = @(
            'http://127.0.0.1/callback'
            "ms-appx-web://Microsoft.AAD.BrokerPlugin/$appId"
            'msauth.com.anthropic.claudefordesktop://auth'
        )
    }
    requiredResourceAccess = @(
        [ordered]@{
            resourceAppId  = $cognitiveServicesAppId
            resourceAccess = @(
                [ordered]@{ id = $userImpersonationScope; type = 'Scope' }
            )
        }
    )
}

$bodyFile = Join-Path ([IO.Path]::GetTempPath()) "claude-appreg-$PID.json"
try {
    $graphBody | ConvertTo-Json -Depth 6 | Set-Content $bodyFile -Encoding utf8
    Invoke-Az @(
        'rest', '--method', 'patch',
        '--uri', "https://graph.microsoft.com/v1.0/applications/$objectId",
        '--headers', 'Content-Type=application/json',
        '--body', "@$bodyFile"
    ) | Out-Null
    Write-Host 'Configured public client flows, redirect URIs and API permission' -ForegroundColor Green
}
finally {
    Remove-Item $bodyFile -ErrorAction SilentlyContinue
}

# A service principal in this tenant is what actually makes the app
# assignable and consentable. Creating it is harmless if it already exists.
Invoke-AzQuiet @('ad', 'sp', 'create', '--id', $appId) | Out-Null

$consentUrl = "https://login.microsoftonline.com/$tenantId/adminconsent?client_id=$appId"

if ($GrantAdminConsent) {
    if (Invoke-AzQuiet @('ad', 'app', 'permission', 'admin-consent', '--id', $appId)) {
        Write-Host 'Granted tenant-wide admin consent' -ForegroundColor Green
    }
    else {
        Write-Host ''
        Write-Host 'Could not grant admin consent - you are not a directory administrator here.' -ForegroundColor Yellow
        Write-Host 'Whether that blocks you depends on one tenant setting:' -ForegroundColor Yellow
        Write-Host '  Entra admin centre > Enterprise applications > Consent and permissions' -ForegroundColor Yellow
        Write-Host 'If user consent is allowed, each user approves the scope at first sign-in and' -ForegroundColor Yellow
        Write-Host "you are fine. If it is set to 'Do not allow user consent', sign-in will stop at" -ForegroundColor Yellow
        Write-Host "'Need admin approval' and an administrator must open:" -ForegroundColor Yellow
        Write-Host "  $consentUrl" -ForegroundColor Yellow
        Write-Host 'Until then, use -CredentialKind static (key-based). See docs/03 and docs/05.' -ForegroundColor Yellow
    }
}
else {
    Write-Host ''
    Write-Host 'No admin consent requested. If this tenant disables self-service consent,' -ForegroundColor DarkGray
    Write-Host "sign-in will stop at 'Need admin approval'. Re-run with -GrantAdminConsent," -ForegroundColor DarkGray
    Write-Host 'or send an administrator this one-off URL:' -ForegroundColor DarkGray
    Write-Host "  $consentUrl" -ForegroundColor DarkGray
}

Write-Host ''
Write-Host ('{0,-16} {1}' -f 'Client ID:', $appId)
Write-Host ('{0,-16} {1}' -f 'Tenant ID:', $tenantId)
Write-Host ('{0,-16} {1}' -f 'Consent URL:', $consentUrl)
Write-Host ''

# The single object this script emits, so callers can do $reg.ClientId.
[pscustomobject]@{
    ClientId   = $appId
    TenantId   = $tenantId
    ObjectId   = $objectId
    Name       = $DisplayName
    ConsentUrl = $consentUrl
}
