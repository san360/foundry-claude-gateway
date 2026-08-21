<#
.SYNOPSIS
    Configures the current PowerShell session so Claude Code talks to Claude
    models in Microsoft Foundry, either directly or through the AI gateway.

.DESCRIPTION
    MUST BE DOT-SOURCED so the environment variables persist in your shell:

        . ./scripts/Set-ClaudeCodeEnv.ps1 -Mode Direct  -Auth Entra
        . ./scripts/Set-ClaudeCodeEnv.ps1 -Mode Gateway -Auth Key

    Reads .deployment-outputs.json written by deploy.ps1.

.PARAMETER Mode
    Direct  - Claude Code calls https://<resource>.services.ai.azure.com/anthropic
    Gateway - Claude Code calls https://<apim>.azure-api.net/anthropic

.PARAMETER Auth
    Entra - use the Azure SDK default credential chain (az login). No secrets.
    Key   - use a static key. Direct mode uses the Foundry key; Gateway mode
            uses the API Management subscription key.

.PARAMETER Token
    Gateway/Direct with Auth=Token: mint a short-lived Entra access token now
    and pin it to ANTHROPIC_FOUNDRY_AUTH_TOKEN. Useful for demonstrating the
    "host application supplies the token" flow. Tokens expire after ~1 hour.
#>
[CmdletBinding()]
param(
    [ValidateSet('Direct', 'Gateway')]
    [string]$Mode = 'Direct',

    [ValidateSet('Entra', 'Key', 'Token')]
    [string]$Auth = 'Entra',

    [string]$OutputsFile
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $OutputsFile) { $OutputsFile = Join-Path $repoRoot '.deployment-outputs.json' }
if (-not (Test-Path $OutputsFile)) {
    throw "Deployment outputs not found at $OutputsFile. Run ./scripts/deploy.ps1 first."
}
$o = Get-Content $OutputsFile -Raw | ConvertFrom-Json

# Start from a clean slate. ANTHROPIC_FOUNDRY_RESOURCE and
# ANTHROPIC_FOUNDRY_BASE_URL are mutually exclusive, and a stale API key
# silently wins over the default credential chain.
foreach ($v in @(
        'ANTHROPIC_FOUNDRY_RESOURCE',
        'ANTHROPIC_FOUNDRY_BASE_URL',
        'ANTHROPIC_FOUNDRY_API_KEY',
        'ANTHROPIC_FOUNDRY_AUTH_TOKEN',
        'ANTHROPIC_API_KEY',
        'ANTHROPIC_AUTH_TOKEN',
        'ANTHROPIC_BASE_URL')) {
    Remove-Item "Env:$v" -ErrorAction SilentlyContinue
}

$env:CLAUDE_CODE_USE_FOUNDRY = '1'

# -- Endpoint ----------------------------------------------------------------
if ($Mode -eq 'Direct') {
    if (-not $o.foundryAccountName) { throw 'foundryAccountName missing from deployment outputs.' }
    $env:ANTHROPIC_FOUNDRY_RESOURCE = $o.foundryAccountName
    $endpoint = $o.foundryAnthropicBaseUrl
}
else {
    if (-not $o.gatewayAnthropicBaseUrl) {
        throw 'gatewayAnthropicBaseUrl missing. Redeploy with deployGateway = true.'
    }
    # Claude Code only appends /anthropic when ANTHROPIC_FOUNDRY_RESOURCE is
    # used, so the gateway base URL must already include the API path.
    $env:ANTHROPIC_FOUNDRY_BASE_URL = $o.gatewayAnthropicBaseUrl
    $endpoint = $o.gatewayAnthropicBaseUrl
}

# -- Credential --------------------------------------------------------------
switch ($Auth) {
    'Entra' {
        # Claude Code falls back to the Azure SDK default credential chain when
        # neither ANTHROPIC_FOUNDRY_API_KEY nor ANTHROPIC_FOUNDRY_AUTH_TOKEN is
        # set. Nothing to do beyond having run 'az login'.
        $whoami = az account show --query user.name -o tsv 2>$null
        if (-not $whoami) { Write-Warning "Not signed in to Azure CLI. Run 'az login'." }
        $credential = "Microsoft Entra ID (default credential chain, signed in as $whoami)"
    }
    'Token' {
        $token = az account get-access-token --resource https://ai.azure.com --query accessToken -o tsv
        if ($LASTEXITCODE -ne 0 -or -not $token) { throw "Could not acquire an Entra token. Run 'az login'." }
        $env:ANTHROPIC_FOUNDRY_AUTH_TOKEN = $token
        $credential = 'Microsoft Entra ID (static bearer token, expires in ~1 hour)'
    }
    'Key' {
        if ($Mode -eq 'Direct') {
            $key = az cognitiveservices account keys list `
                --name $o.foundryAccountName `
                --resource-group $o.resourceGroupName `
                --query key1 -o tsv
            if ($LASTEXITCODE -ne 0 -or -not $key) {
                throw @'
Could not read the Foundry key. If the error mentions disableLocalAuth, keys are off
on this account. Tenant policy enforces that unless the account carries the
SecurityControl=Ignore exemption tag. Redeploy with allowLocalAuthExemption = true -
the tag is honoured on update as well as on create, so an existing account will flip.
Otherwise use -Auth Entra.
'@
            }
            $credential = 'Foundry account API key'
        }
        else {
            $subId = (az account show --query id -o tsv)
            $uri = "/subscriptions/$subId/resourceGroups/$($o.resourceGroupName)" +
            "/providers/Microsoft.ApiManagement/service/$($o.apimName)" +
            "/subscriptions/$($o.gatewaySubscriptionName)/listSecrets?api-version=2024-05-01"
            $key = az rest --method post --uri $uri --query primaryKey -o tsv
            if ($LASTEXITCODE -ne 0 -or -not $key) { throw 'Could not read the API Management subscription key.' }
            $credential = "API Management subscription key (sent as '$($o.gatewaySubscriptionKeyHeader)')"
        }
        $env:ANTHROPIC_FOUNDRY_API_KEY = $key
    }
}

# -- Model pinning -----------------------------------------------------------
# Aliases such as 'sonnet' resolve to Claude Code's built-in Foundry defaults,
# which may not exist in this account. Always pin to real deployment names.
if ($o.sonnetDeploymentName) { $env:ANTHROPIC_DEFAULT_SONNET_MODEL = $o.sonnetDeploymentName }
if ($o.haikuDeploymentName) { $env:ANTHROPIC_DEFAULT_HAIKU_MODEL = $o.haikuDeploymentName }
if ($o.opusDeploymentName) { $env:ANTHROPIC_DEFAULT_OPUS_MODEL = $o.opusDeploymentName }

Write-Host ''
Write-Host 'Claude Code configured' -ForegroundColor Green
'{0,-14} {1}' -f 'Mode:', $Mode
'{0,-14} {1}' -f 'Endpoint:', $endpoint
'{0,-14} {1}' -f 'Credential:', $credential
'{0,-14} {1}' -f 'Sonnet:', $env:ANTHROPIC_DEFAULT_SONNET_MODEL
'{0,-14} {1}' -f 'Haiku:', $env:ANTHROPIC_DEFAULT_HAIKU_MODEL
if ($env:ANTHROPIC_DEFAULT_OPUS_MODEL) { '{0,-14} {1}' -f 'Opus:', $env:ANTHROPIC_DEFAULT_OPUS_MODEL }
Write-Host ''
Write-Host "Run 'claude' and then '/status' to confirm the API provider shows Microsoft Foundry." -ForegroundColor Cyan
