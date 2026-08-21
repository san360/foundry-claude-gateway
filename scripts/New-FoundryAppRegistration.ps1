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
                                         call the Foundry data plane. It is a
                                         user-consentable scope, so a non-admin
                                         can complete sign-in unnoticed; admin
                                         consent just suppresses the prompt.

    Registering all three redirect URIs costs nothing and lets you switch
    -AuthFlow later without touching Entra again.

.PARAMETER DisplayName
    Name of the app registration. Also the lookup key for idempotency.

.PARAMETER SignInAudience
    AzureADMyOrg (default) restricts sign-in to this tenant only.

.PARAMETER GrantAdminConsent
    Pre-consent the delegated scope for the whole tenant so users never see a
    consent prompt. Requires Privileged Role Administrator or Global
    Administrator. Skipped automatically if you lack the permission.

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

if ($GrantAdminConsent) {
    if (Invoke-AzQuiet @('ad', 'app', 'permission', 'admin-consent', '--id', $appId)) {
        Write-Host 'Granted tenant-wide admin consent' -ForegroundColor Green
    }
    else {
        Write-Host 'Could not grant admin consent - you are not a directory administrator in this tenant.' -ForegroundColor Yellow
        Write-Host 'Not a blocker: Cognitive Services user_impersonation is user-consentable, so each' -ForegroundColor Yellow
        Write-Host 'user simply approves it once at first sign-in.' -ForegroundColor Yellow
    }
}

Write-Host ''
Write-Host ('{0,-16} {1}' -f 'Client ID:', $appId)
Write-Host ('{0,-16} {1}' -f 'Tenant ID:', $tenantId)
Write-Host ''

# The single object this script emits, so callers can do $reg.ClientId.
[pscustomobject]@{
    ClientId = $appId
    TenantId = $tenantId
    ObjectId = $objectId
    Name     = $DisplayName
}
