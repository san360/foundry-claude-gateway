<#
.SYNOPSIS
    Writes the .env file holding every setting needed to point Claude Desktop
    and Claude Code at Claude models in Microsoft Foundry, then optionally
    applies it.

.DESCRIPTION
    One file, .env, is the single source of truth for both clients:

      * Claude Desktop reads the inference* settings documented at
        https://claude.com/docs/third-party/claude-desktop/configuration
      * Claude Code (CLI) reads CLAUDE_CODE_USE_FOUNDRY and ANTHROPIC_*.

    Apply the result with ./scripts/Set-ClaudeDesktopConfig.ps1.

    Values come from .deployment-outputs.json (written by deploy.ps1), so the
    endpoint, deployment names and gateway URL are always the live ones.

    The two demo scenarios map onto two DIFFERENT Claude Desktop providers, not
    onto one provider pointed at a different URL:

      -Mode Direct   inferenceProvider = foundry
                     Claude builds https://<resource>.services.ai.azure.com
                     from inferenceFoundryResource and signs in to Entra ID
                     itself using the app registration.

      -Mode Gateway  inferenceProvider = gateway
                     Claude calls the API Management URL verbatim. Foundry is
                     invisible to the client; APIM holds the Foundry identity.

    Both provider blocks are always written. Claude Desktop namespaces its
    settings per provider (inferenceFoundryApiKey vs inferenceGatewayApiKey),
    so the unselected block is inert - which means one .env can describe the
    whole deployment and -Mode only picks which selector line is set. Switching
    scenarios afterwards is a two-line edit, not a regeneration.

    The Claude Code variables at the end of the file are the exception: they are
    process environment variables and there is only one ANTHROPIC_FOUNDRY_API_KEY,
    so those stay scenario-specific with the alternative commented out.

.PARAMETER Mode
    Direct or Gateway. See above.

.PARAMETER CredentialKind
    interactive - the user signs in to Entra ID from inside Claude. No secret
                  is written to .env.
    static      - embed keys in .env. Both the Foundry account key and the API
                  Management subscription key are fetched, so either provider
                  can be selected afterwards without regenerating. Demo-only:
                  the file is gitignored but the keys are still plaintext on
                  disk.

.PARAMETER AuthFlow
    device-code | browser | broker for Direct mode. Gateway mode supports
    browser | broker only - device code is a Foundry-provider flow.

.PARAMETER SessionLifetimeSeconds
    Maps to inferenceSessionLifetimeSec: how long a sign-in stays valid under
    your IdP session policy. Claude shows a re-authenticate banner before it
    expires. It does NOT extend the Entra token lifetime.

.PARAMETER CreateAppRegistration
    Run New-FoundryAppRegistration.ps1 first and use the client ID it returns.

.PARAMETER ClientId
    Use an existing app registration instead of creating one.

.PARAMETER GatewayAudience
    The "aud" claim API Management is configured to accept. Read live from the
    APIM entra-audience named value when not supplied.

    Note the interaction with the gateway's backend auth mode. Under the
    default managed-identity mode APIM replaces the caller's Authorization
    header with its own token before calling Foundry, so the inbound audience
    is purely an authentication gate and can be any resource the client can get
    a token for. Under passthrough mode the caller's own token reaches Foundry,
    so it must be https://ai.azure.com - and that resource cannot be added to a
    custom app registration, which makes passthrough incompatible with Claude
    Desktop's gateway sign-in.

.EXAMPLE
    ./scripts/New-ClaudeConfig.ps1 -Mode Direct -CreateAppRegistration -Apply

.EXAMPLE
    ./scripts/New-ClaudeConfig.ps1 -Mode Gateway -ClientId 5941e251-... -Apply
#>
[CmdletBinding()]
param(
    [ValidateSet('Direct', 'Gateway')]
    [string]$Mode = 'Direct',

    [ValidateSet('interactive', 'static')]
    [string]$CredentialKind = 'interactive',

    [ValidateSet('device-code', 'browser', 'broker')]
    [string]$AuthFlow = 'browser',

    [int]$SessionLifetimeSeconds = 86400,

    [switch]$CreateAppRegistration,

    [string]$ClientId,

    [string]$TenantId,

    [string]$GatewayAudience,

    [string]$UserContentRendererUrl,

    [string]$OutputsFile,

    [string]$EnvFile,

    [switch]$Apply,

    [ValidateSet('Local', 'Policy')]
    [string]$ApplyTarget = 'Local'
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $OutputsFile) { $OutputsFile = Join-Path $repoRoot '.deployment-outputs.json' }
if (-not $EnvFile) { $EnvFile = Join-Path $repoRoot '.env' }

if (-not (Test-Path $OutputsFile)) {
    throw "Deployment outputs not found at $OutputsFile. Run ./scripts/deploy.ps1 first."
}
$o = Get-Content $OutputsFile -Raw | ConvertFrom-Json

if (-not $TenantId) { $TenantId = az account show --query tenantId -o tsv }
$subscriptionId = az account show --query id -o tsv

if ($Mode -eq 'Gateway' -and $AuthFlow -eq 'device-code' -and $CredentialKind -eq 'interactive') {
    throw 'Gateway sign-in supports browser or broker only. Device code is a Foundry-provider flow.'
}

# --- app registration -----------------------------------------------------

if ($CreateAppRegistration) {
    if ($ClientId) { throw 'Specify either -CreateAppRegistration or -ClientId, not both.' }
    $reg = & (Join-Path $PSScriptRoot 'New-FoundryAppRegistration.ps1')
    $ClientId = $reg.ClientId
    $TenantId = $reg.TenantId
}

if ($CredentialKind -eq 'interactive' -and -not $ClientId) {
    throw @'
Interactive sign-in needs a Microsoft Entra ID app registration.

Run one of:
  ./scripts/New-ClaudeConfig.ps1 -CreateAppRegistration ...
  ./scripts/New-ClaudeConfig.ps1 -ClientId <existing-app-id> ...

The client ID is not the tenant ID - they are different objects. A tenant ID in
the "Entra ID client ID" box is the most common cause of AADSTS700016
("application not found in the directory") at sign-in.
'@
}

# --- endpoint -------------------------------------------------------------

if ($Mode -eq 'Gateway') {
    if (-not $o.gatewayAnthropicBaseUrl) {
        throw 'This deployment has no gateway. Redeploy with deployGateway = true, or use -Mode Direct.'
    }
    $baseUrl = $o.gatewayAnthropicBaseUrl
}
else {
    $baseUrl = $o.foundryAnthropicBaseUrl
}

# --- static credentials ---------------------------------------------------

# Both keys are fetched, not just the one for -Mode, because Claude Desktop
# namespaces its settings per provider: inferenceFoundryApiKey and
# inferenceGatewayApiKey can coexist and the unselected one is ignored. Writing
# both makes .env a complete description of the deployment, so switching
# scenarios is an edit to inferenceProvider rather than a regeneration.
#
# Keys are only ever fetched for -CredentialKind static. Writing a secret to
# disk for someone who explicitly asked for interactive sign-in would defeat
# the point of asking.

$foundryKey = ''
$gatewayKey = ''

if ($CredentialKind -eq 'static') {
    $foundryKey = az cognitiveservices account keys list --name $o.foundryAccountName `
        --resource-group $o.resourceGroupName --query key1 -o tsv 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $foundryKey) {
        $foundryKey = ''
        $detail = @'
Could not read a Foundry account key.

If the error mentions disableLocalAuth, keys are switched off on this account.
Tenant policy enforces that unless the account carries the SecurityControl=Ignore
exemption tag. Redeploy with allowLocalAuthExemption = true - the tag is honoured
on update as well as on create, so an existing account will flip. If it does not,
delete the account and redeploy. Otherwise use -CredentialKind interactive.
'@
        # Fatal only when the Foundry key is the credential actually being
        # selected. In Gateway mode it is a bonus, so degrade instead.
        if ($Mode -eq 'Direct') { throw $detail }
        Write-Host ''
        Write-Host $detail -ForegroundColor Yellow
        Write-Host 'Continuing: -Mode Gateway does not need it.' -ForegroundColor Yellow
    }

    if ($o.gatewayAnthropicBaseUrl -and $o.apimName -and $o.gatewaySubscriptionName) {
        $uri = "/subscriptions/$subscriptionId/resourceGroups/$($o.resourceGroupName)" +
        "/providers/Microsoft.ApiManagement/service/$($o.apimName)" +
        "/subscriptions/$($o.gatewaySubscriptionName)/listSecrets?api-version=2024-05-01"
        $gatewayKey = az rest --method post --uri $uri --query primaryKey -o tsv 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $gatewayKey) {
            $gatewayKey = ''
            if ($Mode -eq 'Gateway') {
                throw "Could not read the API Management subscription key for '$($o.gatewaySubscriptionName)'. Check that you have rights to listSecrets on $($o.apimName)."
            }
            Write-Host ''
            Write-Host 'Could not read the API Management subscription key; omitting it from .env.' -ForegroundColor Yellow
        }

        # Claude Desktop can send a gateway credential as "Authorization:
        # Bearer" or as "x-api-key" - those are the only two schemes it knows.
        # API Management must therefore be told to look for the subscription
        # key on x-api-key, which is a deployment parameter, not a client one.
        if ($gatewayKey -and $o.gatewaySubscriptionKeyHeader -and $o.gatewaySubscriptionKeyHeader -ne 'x-api-key') {
            Write-Host ''
            Write-Host "The gateway expects its subscription key on '$($o.gatewaySubscriptionKeyHeader)', but Claude" -ForegroundColor Yellow
            Write-Host "Desktop can only send 'Authorization: Bearer' or 'x-api-key'." -ForegroundColor Yellow
            Write-Host 'Redeploy with gatewaySubscriptionKeyHeader = x-api-key, or use -CredentialKind interactive.' -ForegroundColor Yellow
        }
    }
}

# The key matching the selected provider - what Claude Code and the summary use.
$apiKey = if ($Mode -eq 'Gateway') { $gatewayKey } else { $foundryKey }

# --- model list -----------------------------------------------------------

function Get-FamilyTier {
    param([string]$DeploymentName)
    switch -Regex ($DeploymentName) {
        'opus' { return 'opus' }
        'sonnet' { return 'sonnet' }
        'haiku' { return 'haiku' }
        default { return 'sonnet' }
    }
}

$models = @($o.sonnetDeploymentName, $o.opusDeploymentName, $o.haikuDeploymentName) |
    Where-Object { $_ }
if (-not $models) { throw 'The deployment exposes no Claude models.' }

# "name" is the Foundry DEPLOYMENT name, which is what the Messages API expects
# in its "model" field - not the underlying model ID. Built by hand because
# ConvertTo-Json collapses a single-element array into an object on Windows
# PowerShell 5.1, where -AsArray does not exist.
$modelJson = '[' + (($models | ForEach-Object {
            [ordered]@{
                name                = $_
                labelOverride       = $_
                anthropicFamilyTier = Get-FamilyTier $_
            } | ConvertTo-Json -Compress
        }) -join ',') + ']'

# --- .env -----------------------------------------------------------------

function Format-EnvValue {
    param([string]$Value)
    # Quote when empty, or when the value holds characters a POSIX shell would
    # interpret, so the same file is safe to `source` on macOS and Linux.
    if ($Value -eq '' -or $Value -match '[\s"''#$&|<>(){}]') {
        return '"' + ($Value -replace '\\', '\\\\' -replace '"', '\"') + '"'
    }
    return $Value
}

$lines = [System.Collections.Generic.List[string]]::new()
function Add-Line { param([string]$Text) $lines.Add($Text) }
function Add-Setting {
    param([string]$Key, $Value)
    $lines.Add("$Key=$(Format-EnvValue ([string]$Value))")
}

Add-Line '# Claude on Microsoft Foundry - generated by scripts/New-ClaudeConfig.ps1'
Add-Line "# Generated : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')"
Add-Line "# Active    : $Mode + $CredentialKind"
Add-Line '#'
Add-Line '# Both providers are described in this file. The two selector lines'
Add-Line '# inferenceProvider and inferenceCredentialKind decide which combination is'
Add-Line '# live for Claude Desktop; everything else is ignored until selected.'
Add-Line '#'
Add-Line '# Gitignored. Regenerate freely; do not hand-edit deployment-derived values.'
Add-Line '# Apply with: ./scripts/Set-ClaudeDesktopConfig.ps1'
Add-Line ''

Add-Line '# ---------------------------------------------------------------------'
Add-Line '# Azure context - informational, not read by either client'
Add-Line '# ---------------------------------------------------------------------'
Add-Setting 'AZURE_TENANT_ID' $TenantId
Add-Setting 'AZURE_SUBSCRIPTION_ID' $subscriptionId
Add-Setting 'AZURE_RESOURCE_GROUP' $o.resourceGroupName
Add-Setting 'FOUNDRY_ACCOUNT_NAME' $o.foundryAccountName
Add-Setting 'FOUNDRY_ANTHROPIC_BASE_URL' $o.foundryAnthropicBaseUrl
if ($o.gatewayAnthropicBaseUrl) { Add-Setting 'GATEWAY_ANTHROPIC_BASE_URL' $o.gatewayAnthropicBaseUrl }
if ($ClientId) { Add-Setting 'ENTRA_APP_CLIENT_ID' $ClientId }
Add-Line ''

Add-Line '# ---------------------------------------------------------------------'
Add-Line '# Claude Desktop'
Add-Line '# https://claude.com/docs/third-party/claude-desktop/configuration'
Add-Line '# ---------------------------------------------------------------------'
Add-Line ''
Add-Line '# Selects the backend. Setting this activates third-party mode.'
Add-Setting 'inferenceProvider' $(if ($Mode -eq 'Gateway') { 'gateway' } else { 'foundry' })
Add-Line ''
Add-Line '# Credential source. When set, only that source is used - no fallback.'
Add-Setting 'inferenceCredentialKind' $CredentialKind
Add-Line ''
Add-Line '# How long a sign-in stays valid under your IdP session policy.'
Add-Setting 'inferenceSessionLifetimeSec' $SessionLifetimeSeconds
Add-Line ''

Add-Line '# Both provider blocks are written. inferenceProvider above selects which'
Add-Line '# one is live; Claude Desktop ignores the other. Switching scenario is an'
Add-Line '# edit to these two selector lines, not a regeneration.'
Add-Line ''

Add-Line '# --- Foundry provider (inferenceProvider=foundry) ---'
Add-Line '# Resource name; Claude constructs the endpoint URL from it.'
Add-Setting 'inferenceFoundryResource' $o.foundryAccountName
Add-Line ''
Add-Line '# Directory (tenant) ID of the app registration that holds the'
Add-Line '# Cognitive Services scope.'
Add-Setting 'inferenceFoundryTenantId' $TenantId
Add-Line ''
Add-Line '# Application (client) ID of that registration. NOT the tenant ID.'
if (-not $ClientId) {
    Add-Line '# Empty: no -ClientId was supplied. Required before inferenceCredentialKind'
    Add-Line '# can be switched to interactive.'
}
Add-Setting 'inferenceFoundryClientId' $ClientId
Add-Line ''
Add-Line '# device-code | browser | broker'
Add-Setting 'inferenceFoundryAuthFlow' $AuthFlow
Add-Line ''
if ($foundryKey) {
    Add-Line '# Foundry account key, used only when inferenceCredentialKind=static.'
    Add-Line '# Shared across every caller and not individually revocable - rotating it'
    Add-Line '# cuts off everyone. The gateway key below is the better key story.'
}
else {
    Add-Line '# Empty under interactive sign-in, which is the point.'
}
Add-Setting 'inferenceFoundryApiKey' $foundryKey
Add-Line ''

if ($o.gatewayAnthropicBaseUrl) {
    Add-Line '# --- Gateway provider (inferenceProvider=gateway) ---'
    Add-Line '# Full gateway URL, including the /anthropic suffix.'
    Add-Setting 'inferenceGatewayBaseUrl' $o.gatewayAnthropicBaseUrl
    Add-Line ''

    if ($gatewayKey) {
        Add-Line '# API Management subscription key, used only when'
        Add-Line '# inferenceCredentialKind=static. Per-consumer, individually revocable,'
        Add-Line '# and it grants nothing on Foundry itself.'
        Add-Line '# bearer | x-api-key are the only two schemes Claude Desktop can send,'
        Add-Line '# so APIM is configured to read its subscription key from x-api-key.'
        Add-Setting 'inferenceGatewayApiKey' $gatewayKey
        Add-Setting 'inferenceGatewayAuthScheme' 'x-api-key'
        Add-Line ''
    }

    if ($ClientId) {
        Add-Line '# Entra ID sign-in, used only when inferenceCredentialKind=interactive.'
        Add-Line '# Claude mints an access token for the audience the gateway validates'
        Add-Line '# and sends it as Authorization: Bearer.'
        Add-Line '# The gateway must validate iss AND aud - a signature check alone'
        Add-Line '# would accept any token from the tenant. The APIM policy does both.'

        # Use the audience APIM actually enforces rather than assuming it.
        # A mismatch fails at sign-in with AADSTS500011 or at the gateway with
        # 401, and the two look nothing alike from the client side.
        if (-not $GatewayAudience) {
            $accepted = @($o.gatewayEntraAudiences) | Where-Object { $_ }
            if (-not $accepted) {
                $nvUri = "/subscriptions/$subscriptionId/resourceGroups/$($o.resourceGroupName)" +
                "/providers/Microsoft.ApiManagement/service/$($o.apimName)" +
                '/namedValues/entra-audience?api-version=2024-05-01'
                $live = az rest --method get --uri $nvUri --query properties.value -o tsv 2>$null
                if ($LASTEXITCODE -eq 0 -and $live) { $accepted = @($live) }
            }

            # Only a resource with a service principal in the tenant can be
            # added to a custom app registration. https://ai.azure.com is
            # issuable to first-party clients but exposes no enumerable
            # principal, so prefer any other audience the gateway accepts.
            $usable = $accepted | Where-Object { $_ -ne 'https://ai.azure.com' } | Select-Object -First 1
            if ($usable) { $GatewayAudience = $usable }
            elseif ($accepted) {
                Write-Host ''
                Write-Host 'The gateway accepts only aud = https://ai.azure.com. That resource has no' -ForegroundColor Yellow
                Write-Host 'service principal a custom app registration can be granted, so Claude Desktop' -ForegroundColor Yellow
                Write-Host 'cannot mint a token for it. Redeploy the gateway - the current template also' -ForegroundColor Yellow
                Write-Host 'accepts https://cognitiveservices.azure.com, which Claude Desktop can obtain.' -ForegroundColor Yellow
                $GatewayAudience = 'https://cognitiveservices.azure.com'
            }
            else {
                $GatewayAudience = 'https://cognitiveservices.azure.com'
            }
        }

        $oidc = [ordered]@{
            issuer    = "https://login.microsoftonline.com/$TenantId/v2.0"
            clientId  = $ClientId
            tokenType = 'access_token'
            scopes    = @("$GatewayAudience/.default")
        } | ConvertTo-Json -Compress
        Add-Setting 'inferenceGatewayOidc' $oidc

        # Device code is a Foundry-provider flow; the gateway provider knows
        # only browser and broker.
        Add-Setting 'inferenceGatewayOidcAuthFlow' $(if ($AuthFlow -eq 'broker') { 'broker' } else { 'browser' })
        Add-Line ''
    }
}
Add-Line '# Model picker contents. "name" is the Foundry deployment name and the'
Add-Line '# first entry is the default.'
Add-Setting 'inferenceModels' $modelJson
Add-Line ''
Add-Line '# Foundry exposes no Anthropic model-listing endpoint, so discovery'
Add-Line '# stays off and the list above is authoritative.'
Add-Setting 'modelDiscoveryEnabled' 'false'
Add-Line ''
Add-Line '# HTTPS origin for artifact previews. Empty uses the commercial host.'
Add-Setting 'userContentRendererUrl' $UserContentRendererUrl
Add-Line ''

Add-Line '# ---------------------------------------------------------------------'
Add-Line '# Claude Code (CLI)'
Add-Line '#'
Add-Line '# Unlike the Claude Desktop settings above, these are process environment'
Add-Line "# variables and they collide: there is one ANTHROPIC_FOUNDRY_API_KEY, not"
Add-Line '# one per provider. Only the selected scenario is live; the alternative is'
Add-Line '# commented out directly beneath it.'
Add-Line '# ---------------------------------------------------------------------'
Add-Setting 'CLAUDE_CODE_USE_FOUNDRY' '1'
Add-Line ''
if ($Mode -eq 'Gateway') {
    Add-Line '# Gateway: the base URL must already include /anthropic.'
    Add-Setting 'ANTHROPIC_FOUNDRY_BASE_URL' $baseUrl
    if ($gatewayKey) { Add-Setting 'ANTHROPIC_FOUNDRY_API_KEY' $gatewayKey }
    Add-Line ''
    Add-Line '# Direct instead: comment the two lines above and uncomment these.'
    Add-Line "# ANTHROPIC_FOUNDRY_RESOURCE=$($o.foundryAccountName)"
    if ($foundryKey) { Add-Line "# ANTHROPIC_FOUNDRY_API_KEY=$foundryKey" }
}
else {
    Add-Line '# Direct: Claude Code appends /anthropic to the resource name itself.'
    Add-Setting 'ANTHROPIC_FOUNDRY_RESOURCE' $o.foundryAccountName
    if ($foundryKey) { Add-Setting 'ANTHROPIC_FOUNDRY_API_KEY' $foundryKey }
    if ($o.gatewayAnthropicBaseUrl) {
        Add-Line ''
        Add-Line '# Gateway instead: comment the two lines above and uncomment these.'
        Add-Line "# ANTHROPIC_FOUNDRY_BASE_URL=$($o.gatewayAnthropicBaseUrl)"
        if ($gatewayKey) { Add-Line "# ANTHROPIC_FOUNDRY_API_KEY=$gatewayKey" }
    }
}
Add-Line ''
Add-Line '# Pin every model. Foundry performs no startup model check, so an'
Add-Line '# unpinned alias fails at the first request rather than at launch.'
if ($o.sonnetDeploymentName) { Add-Setting 'ANTHROPIC_DEFAULT_SONNET_MODEL' $o.sonnetDeploymentName }
if ($o.opusDeploymentName) { Add-Setting 'ANTHROPIC_DEFAULT_OPUS_MODEL' $o.opusDeploymentName }
if ($o.haikuDeploymentName) { Add-Setting 'ANTHROPIC_DEFAULT_HAIKU_MODEL' $o.haikuDeploymentName }

Set-Content -Path $EnvFile -Value $lines -Encoding utf8

Write-Host ''
Write-Host "Wrote $EnvFile" -ForegroundColor Green
Write-Host ''
Write-Host ('{0,-20} {1}' -f 'Scenario:', $Mode)
Write-Host ('{0,-20} {1}' -f 'Provider:', $(if ($Mode -eq 'Gateway') { 'gateway' } else { 'foundry' }))
Write-Host ('{0,-20} {1}' -f 'Endpoint:', $baseUrl)
Write-Host ('{0,-20} {1}' -f 'Credential:', $CredentialKind)
Write-Host ('{0,-20} {1}' -f 'Sign-in flow:', $AuthFlow)
Write-Host ('{0,-20} {1}' -f 'Tenant ID:', $TenantId)
Write-Host ('{0,-20} {1}' -f 'Client ID:', $(if ($ClientId) { $ClientId } else { '(none - static credential)' }))
Write-Host ('{0,-20} {1}' -f 'Models:', ($models -join ', '))
Write-Host ('{0,-20} {1}' -f 'Foundry key:', $(if ($foundryKey) { 'written' } else { 'not written' }))
Write-Host ('{0,-20} {1}' -f 'Gateway key:', $(if ($gatewayKey) { 'written' } else { 'not written' }))
Write-Host ''

if ($Apply) {
    & (Join-Path $PSScriptRoot 'Set-ClaudeDesktopConfig.ps1') -EnvFile $EnvFile -Target $ApplyTarget
}
else {
    Write-Host 'Apply it with: ./scripts/Set-ClaudeDesktopConfig.ps1' -ForegroundColor DarkGray
}
