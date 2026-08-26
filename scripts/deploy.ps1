<#
.SYNOPSIS
    Deploys the Claude on Microsoft Foundry demo environment (direct + AI gateway).

.DESCRIPTION
    Runs a subscription-scoped Bicep deployment, then writes the deployment
    outputs to .deployment-outputs.json at the repository root so the other
    scripts in this folder can configure Claude Code without manual copy/paste.

.PARAMETER Location
    Azure region for the deployment. Must offer the selected Claude models.

.PARAMETER ParameterFile
    Path to the .bicepparam file. Defaults to infra/main.bicepparam.

.PARAMETER SubscriptionId
    Optional subscription to deploy into. Defaults to the current az context.

.PARAMETER GatewaySsoAppId
    Client ID of the Claude Desktop interactive sign-in app registration, from
    scripts/New-GatewaySsoAppRegistration.ps1. Adds that app as an accepted
    audience at the gateway.

.PARAMETER AllowedGroupId
    Object IDs of Entra groups permitted to call the gateway with an interactive
    sign-in token. Omit to accept any authenticated user. Repeatable.

.PARAMETER GrantSelfAccess
    Look up the signed-in user's object ID and pass it as principalId so the
    Entra ID path works immediately after deployment.

.PARAMETER WhatIf
    Run a what-if preview instead of deploying.

.EXAMPLE
    ./scripts/deploy.ps1 -GrantSelfAccess

.EXAMPLE
    ./scripts/deploy.ps1 -Location swedencentral -WhatIf
#>
[CmdletBinding()]
param(
    [string]$Location = 'eastus2',
    [string]$ParameterFile,
    [string]$SubscriptionId,
    [string]$GatewaySsoAppId,
    [string[]]$AllowedGroupId = @(),
    [switch]$GrantSelfAccess,
    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $ParameterFile) {
    $ParameterFile = Join-Path $repoRoot 'infra/main.bicepparam'
}
$templateFile = Join-Path $repoRoot 'infra/main.bicep'

foreach ($path in @($templateFile, $ParameterFile)) {
    if (-not (Test-Path $path)) { throw "Not found: $path" }
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI (az) is required. See https://learn.microsoft.com/cli/azure/install-azure-cli'
}

# Verify the CLI is signed in before doing anything expensive.
$account = az account show -o json 2>$null | ConvertFrom-Json
if (-not $account) { throw "Not signed in. Run 'az login' first." }

if ($SubscriptionId) {
    az account set --subscription $SubscriptionId | Out-Null
    $account = az account show -o json | ConvertFrom-Json
}

Write-Host "Subscription : $($account.name) ($($account.id))" -ForegroundColor Cyan
Write-Host "Location     : $Location" -ForegroundColor Cyan

$extraParams = @()
if ($GrantSelfAccess) {
    $objectId = az ad signed-in-user show --query id -o tsv 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $objectId) {
        Write-Warning 'Could not resolve the signed-in user object ID. Skipping the RBAC grant; assign Cognitive Services User manually.'
    }
    else {
        Write-Host "Principal    : $objectId (Cognitive Services User)" -ForegroundColor Cyan
        $extraParams += @("principalId=$objectId", 'principalType=User')
    }
}

if ($GatewaySsoAppId) {
    Write-Host "Gateway SSO  : $GatewaySsoAppId" -ForegroundColor Cyan
    $extraParams += "gatewaySsoAppId=$GatewaySsoAppId"
}

if ($AllowedGroupId.Count) {
    Write-Host "Allowed group: $($AllowedGroupId -join ', ')" -ForegroundColor Cyan
    # Comma-separated rather than a JSON array: an inline array override has to
    # arrive as JSON, and the Azure CLI's own argument parsing strips the inner
    # double quotes on Windows, so it never survives to ARM.
    $extraParams += "gatewayAllowedGroupIds=$($AllowedGroupId -join ',')"
}

$deploymentName = "claude-foundry-$(Get-Date -Format 'yyyyMMddHHmmss')"

# Every inline override has to follow ONE --parameters switch. Repeating the
# switch makes the CLI concatenate the values into the preceding parameter, so
# principalId arrives as "<guid> principalType=User" and ARM rejects it with
# InvalidPrincipalId.
$inlineParams = @("location=$Location") + $extraParams

$azArgs = @(
    'deployment', 'sub', 'create',
    '--name', $deploymentName,
    '--location', $Location,
    '--template-file', $templateFile,
    '--parameters', $ParameterFile,
    '--parameters'
) + $inlineParams

if ($WhatIf) {
    $azArgs = @('deployment', 'sub', 'what-if',
        '--location', $Location,
        '--template-file', $templateFile,
        '--parameters', $ParameterFile,
        '--parameters') + $inlineParams
    Write-Host 'Running what-if preview...' -ForegroundColor Yellow
    az @azArgs
    return
}

Write-Host 'Deploying. API Management provisioning dominates the runtime (roughly 15-45 minutes on first create).' -ForegroundColor Yellow

$result = az @azArgs -o json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or -not $result) { throw 'Deployment failed. Review the Azure CLI output above.' }

$outputs = [ordered]@{}
foreach ($key in $result.properties.outputs.PSObject.Properties.Name) {
    $outputs[$key] = $result.properties.outputs.$key.value
}

$outputsPath = Join-Path $repoRoot '.deployment-outputs.json'
$outputs | ConvertTo-Json -Depth 5 | Set-Content -Path $outputsPath -Encoding utf8

Write-Host ''
Write-Host 'Deployment complete.' -ForegroundColor Green
Write-Host "Outputs written to $outputsPath" -ForegroundColor Green
Write-Host ''
$outputs.GetEnumerator() | Where-Object { $_.Value } | ForEach-Object {
    '{0,-30} {1}' -f $_.Key, $_.Value
}
Write-Host ''
Write-Host 'Next steps:' -ForegroundColor Cyan
Write-Host '  Direct path   : . ./scripts/Set-ClaudeCodeEnv.ps1 -Mode Direct -Auth Entra'
Write-Host '  Gateway path  : . ./scripts/Set-ClaudeCodeEnv.ps1 -Mode Gateway -Auth Key'
Write-Host '  Smoke test    : ./scripts/Test-ClaudeEndpoint.ps1 -Mode Direct -Auth Entra'


