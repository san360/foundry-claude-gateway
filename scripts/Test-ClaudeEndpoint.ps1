<#
.SYNOPSIS
    Smoke-tests the Anthropic Messages API on Foundry, directly or via the AI gateway.

.DESCRIPTION
    Sends a real /v1/messages request and prints the model reply plus the
    response headers that prove which path was taken (x-gateway,
    x-gateway-tokens-remaining). Run it before demoing Claude Code so you know
    the endpoint, credential and RBAC are all working.

.EXAMPLE
    ./scripts/Test-ClaudeEndpoint.ps1 -Mode Direct -Auth Entra

.EXAMPLE
    ./scripts/Test-ClaudeEndpoint.ps1 -Mode Gateway -Auth Key -Model claude-sonnet-4-6
#>
[CmdletBinding()]
param(
    [ValidateSet('Direct', 'Gateway')]
    [string]$Mode = 'Direct',

    [ValidateSet('Entra', 'Key')]
    [string]$Auth = 'Entra',

    [string]$Model,
    [string]$Prompt = 'Reply with exactly one short sentence confirming you are Claude running in Microsoft Foundry.',
    [string]$OutputsFile
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $OutputsFile) { $OutputsFile = Join-Path $repoRoot '.deployment-outputs.json' }
if (-not (Test-Path $OutputsFile)) {
    throw "Deployment outputs not found at $OutputsFile. Run ./scripts/deploy.ps1 first."
}
$o = Get-Content $OutputsFile -Raw | ConvertFrom-Json

if (-not $Model) {
    $Model = if ($o.sonnetDeploymentName) { $o.sonnetDeploymentName } else { $o.haikuDeploymentName }
}
if (-not $Model) { throw 'No model deployment found in the outputs. Pass -Model explicitly.' }

$baseUrl = if ($Mode -eq 'Direct') { $o.foundryAnthropicBaseUrl } else { $o.gatewayAnthropicBaseUrl }
if (-not $baseUrl) { throw "No base URL for mode '$Mode' in the deployment outputs." }

$uri = "$($baseUrl.TrimEnd('/'))/v1/messages"

$headers = @{
    'anthropic-version' = '2023-06-01'
    'Content-Type'      = 'application/json'
}

switch ($Auth) {
    'Entra' {
        # The Anthropic surface of Foundry issues tokens for https://ai.azure.com.
        $token = az account get-access-token --resource https://ai.azure.com --query accessToken -o tsv
        if ($LASTEXITCODE -ne 0 -or -not $token) { throw "Could not acquire an Entra token. Run 'az login'." }
        $headers['Authorization'] = "Bearer $token"
    }
    'Key' {
        if ($Mode -eq 'Direct') {
            $key = az cognitiveservices account keys list --name $o.foundryAccountName `
                --resource-group $o.resourceGroupName --query key1 -o tsv
            if ($LASTEXITCODE -ne 0 -or -not $key) {
                throw @'
Could not read the Foundry key.

If the error mentions "disableLocalAuth is set to be true", API keys are turned off on
this account. Many enterprise tenants enforce that with an Azure Policy modify effect,
which overrides the template's disableFoundryLocalAuth = false. Confirm with:

  az cognitiveservices account show -n <account> -g <rg> --query properties.disableLocalAuth

Re-run this script with -Auth Entra. See docs/07-troubleshooting.md.
'@
            }
            $headers['api-key'] = $key
        }
        else {
            $subId = az account show --query id -o tsv
            $listUri = "/subscriptions/$subId/resourceGroups/$($o.resourceGroupName)" +
            "/providers/Microsoft.ApiManagement/service/$($o.apimName)" +
            "/subscriptions/$($o.gatewaySubscriptionName)/listSecrets?api-version=2024-05-01"
            $key = az rest --method post --uri $listUri --query primaryKey -o tsv
            if ($LASTEXITCODE -ne 0 -or -not $key) { throw 'Could not read the API Management subscription key.' }
            $headerName = if ($o.gatewaySubscriptionKeyHeader) { $o.gatewaySubscriptionKeyHeader } else { 'api-key' }
            $headers[$headerName] = $key
        }
    }
}

$body = @{
    model      = $Model
    max_tokens = 200
    messages   = @(@{ role = 'user'; content = $Prompt })
} | ConvertTo-Json -Depth 5

Write-Host ''
'{0,-12} {1}' -f 'Endpoint:', $uri
'{0,-12} {1}' -f 'Model:', $Model
'{0,-12} {1}' -f 'Auth:', $Auth
Write-Host ''

try {
    $response = Invoke-WebRequest -Uri $uri -Method Post -Headers $headers -Body $body -TimeoutSec 120
}
catch {
    $status = $_.Exception.Response.StatusCode.value__
    Write-Host "FAILED (HTTP $status)" -ForegroundColor Red
    if ($_.ErrorDetails.Message) { Write-Host $_.ErrorDetails.Message }
    switch ($status) {
        401 { Write-Host "Hint: check RBAC. The caller needs 'Cognitive Services User' on the Foundry account." -ForegroundColor Yellow }
        403 { Write-Host 'Hint: the credential is valid but not authorized. Role assignments can take a few minutes.' -ForegroundColor Yellow }
        404 { Write-Host "Hint: the 'model' field must be the Foundry DEPLOYMENT name, not the model ID." -ForegroundColor Yellow }
        429 { Write-Host 'Hint: the gateway token-per-minute budget or the deployment capacity was exceeded.' -ForegroundColor Yellow }
    }
    throw
}

$payload = $response.Content | ConvertFrom-Json

Write-Host 'SUCCESS' -ForegroundColor Green
Write-Host ''
Write-Host ($payload.content | Where-Object { $_.type -eq 'text' } | Select-Object -ExpandProperty text)
Write-Host ''
'{0,-26} {1}' -f 'Reported model:', $payload.model
'{0,-26} {1}' -f 'Input tokens:', $payload.usage.input_tokens
'{0,-26} {1}' -f 'Output tokens:', $payload.usage.output_tokens

foreach ($h in 'x-gateway', 'x-gateway-tokens-remaining', 'x-gateway-tokens-consumed', 'x-ms-region') {
    if ($response.Headers.ContainsKey($h)) {
        '{0,-26} {1}' -f "$($h):", ($response.Headers[$h] -join ', ')
    }
}
Write-Host ''
if ($Mode -eq 'Gateway' -and -not $response.Headers.ContainsKey('x-gateway')) {
    Write-Warning 'The x-gateway header is missing. The request may not have traversed API Management.'
}
