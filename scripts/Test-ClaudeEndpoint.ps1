<#
.SYNOPSIS
    Smoke-tests the Anthropic Messages API on Foundry, directly or via the AI gateway.

.DESCRIPTION
    Sends a real /v1/messages request and prints the model reply plus the
    response headers that prove which path was taken (x-gateway,
    x-gateway-tokens-remaining). Run it before demoing Claude Code so you know
    the endpoint, credential and RBAC are all working.

    With -ListModels it calls GET /v1/models instead. That endpoint is a
    gateway-only capability: Foundry's Anthropic surface answers 404
    api_not_supported, while the gateway synthesises the list from the
    account's Anthropic-format deployments. Running it in both modes is the
    quickest way to show what the gateway adds.

.EXAMPLE
    ./scripts/Test-ClaudeEndpoint.ps1 -Mode Direct -Auth Entra

.EXAMPLE
    ./scripts/Test-ClaudeEndpoint.ps1 -Mode Gateway -Auth Key -Model claude-sonnet-4-6

.EXAMPLE
    ./scripts/Test-ClaudeEndpoint.ps1 -Mode Gateway -Auth Key -ListModels
#>
[CmdletBinding()]
param(
    [ValidateSet('Direct', 'Gateway')]
    [string]$Mode = 'Direct',

    [ValidateSet('Entra', 'Key')]
    [string]$Auth = 'Entra',

    [string]$Model,
    [string]$Prompt = 'Reply with exactly one short sentence confirming you are Claude running in Microsoft Foundry.',

    [switch]$ListModels,

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

$uri = if ($ListModels) { "$($baseUrl.TrimEnd('/'))/v1/models" } else { "$($baseUrl.TrimEnd('/'))/v1/messages" }

$headers = @{
    'anthropic-version' = '2023-06-01'
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
this account. Tenant policy enforces that with an Azure Policy modify effect, which
overrides the template's disableFoundryLocalAuth = false unless the account carries the
SecurityControl=Ignore exemption tag. Confirm:

  az cognitiveservices account show -n <account> -g <rg> --query "{localAuth:properties.disableLocalAuth,tags:tags}"

Redeploy with allowLocalAuthExemption = true. The tag is honoured on update as well as
on create, so an already-hardened account will flip back on the next deployment; only
if it does not is a delete-and-redeploy needed. Otherwise re-run with -Auth Entra.
See docs/07-troubleshooting.md.
'@
            }
            # The Anthropic surface expects Anthropic's own header. 'api-key',
            # which the Azure OpenAI surface of the same account accepts, is
            # rejected here with a 401.
            $headers['x-api-key'] = $key
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
if (-not $ListModels) { '{0,-12} {1}' -f 'Model:', $Model }
'{0,-12} {1}' -f 'Auth:', $Auth
Write-Host ''

try {
    # -UseBasicParsing is required on Windows PowerShell 5.1: the default parser
    # depends on the Internet Explorer engine and throws "Windows PowerShell is in
    # NonInteractive mode" under automation. It is a harmless no-op on PowerShell 7+.
    # The body is sent as UTF-8 bytes so non-ASCII prompts are not mangled.
    if ($ListModels) {
        $response = Invoke-WebRequest -Uri $uri -Method Get -Headers $headers -TimeoutSec 120 -UseBasicParsing
    }
    else {
        $response = Invoke-WebRequest -Uri $uri -Method Post -Headers $headers -TimeoutSec 120 `
            -ContentType 'application/json' -UseBasicParsing `
            -Body ([Text.Encoding]::UTF8.GetBytes($body))
    }
}
catch {
    $status = $_.Exception.Response.StatusCode.value__
    Write-Host "FAILED (HTTP $status)" -ForegroundColor Red
    if ($_.ErrorDetails.Message) { Write-Host $_.ErrorDetails.Message }
    switch ($status) {
        401 {
            Write-Host "Hint: check RBAC. The caller needs 'Cognitive Services User' on the Foundry account." -ForegroundColor Yellow
            if ($Mode -eq 'Gateway' -and $Auth -eq 'Key') {
                Write-Host "Hint: if backend-auth-mode is 'passthrough', a subscription-key-only caller has no Entra token to forward, so Foundry rejects it. Use -Auth Entra, or run ./scripts/Set-GatewayAuthMode.ps1 -BackendAuth managedIdentity." -ForegroundColor Yellow
            }
        }
        403 { Write-Host 'Hint: the credential is valid but not authorized. Role assignments can take a few minutes.' -ForegroundColor Yellow }
        404 {
            if ($ListModels -and $Mode -eq 'Direct') {
                Write-Host "Expected. Foundry's Anthropic surface does not implement /v1/models, which is why Claude Desktop's 'Model discovery' toggle only works through the gateway. Re-run with -Mode Gateway." -ForegroundColor Yellow
            }
            elseif ($ListModels) {
                Write-Host 'Hint: model discovery is switched off at the gateway. Redeploy with gatewayModelDiscovery = true.' -ForegroundColor Yellow
            }
            else {
                Write-Host "Hint: the 'model' field must be the Foundry DEPLOYMENT name, not the model ID." -ForegroundColor Yellow
            }
        }
        429 { Write-Host 'Hint: the gateway token-per-minute budget or the deployment capacity was exceeded.' -ForegroundColor Yellow }
    }
    throw
}

$payload = if ($response.RawContentStream) {
    # Windows PowerShell 5.1 decodes .Content with the response charset guessed from
    # headers and mangles multi-byte UTF-8 (em dashes, smart quotes) in model output.
    # Decoding the raw bytes explicitly keeps the text intact on both 5.1 and 7+.
    $ms = New-Object IO.MemoryStream
    $response.RawContentStream.Position = 0
    $response.RawContentStream.CopyTo($ms)
    [Text.Encoding]::UTF8.GetString($ms.ToArray()) | ConvertFrom-Json
}
else {
    $response.Content | ConvertFrom-Json
}

Write-Host 'SUCCESS' -ForegroundColor Green
Write-Host ''

if ($ListModels) {
    if ($payload.data) {
        $payload.data | ForEach-Object {
            '{0,-26} {1}' -f $_.id, $_.created_at
        }
    }
    else {
        Write-Warning 'The endpoint returned an empty model list. See docs/07-troubleshooting.md.'
    }
    Write-Host ''
    '{0,-26} {1}' -f 'Models returned:', @($payload.data).Count
    if ($response.Headers.ContainsKey('x-gateway-synthesised')) {
        '{0,-26} {1}' -f 'Synthesised by:', 'the gateway (Foundry does not implement this endpoint)'
    }
    foreach ($h in 'x-gateway', 'x-ms-region') {
        if ($response.Headers.ContainsKey($h)) {
            '{0,-26} {1}' -f "$($h):", ($response.Headers[$h] -join ', ')
        }
    }
    Write-Host ''
    return
}

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
