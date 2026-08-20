<#
.SYNOPSIS
    Switches the AI gateway authentication topology at runtime, without redeploying.

.DESCRIPTION
    The API Management policy reads two named values. Updating them takes
    effect on the next request, which makes for a compelling live demo:

      -ClientAuth  subscriptionKey | entra | either
          How callers authenticate TO the gateway.

      -BackendAuth managedIdentity | passthrough
          How the gateway authenticates TO Foundry.
            managedIdentity - the gateway swaps the caller credential for its
                              own MI token; clients never hold a Foundry key.
            passthrough     - the caller's Entra token is forwarded unchanged;
                              Foundry enforces per-user RBAC.

.EXAMPLE
    ./scripts/Set-GatewayAuthMode.ps1 -ClientAuth entra -BackendAuth passthrough

.EXAMPLE
    ./scripts/Set-GatewayAuthMode.ps1 -Show
#>
[CmdletBinding()]
param(
    [ValidateSet('subscriptionKey', 'entra', 'either')]
    [string]$ClientAuth,

    [ValidateSet('managedIdentity', 'passthrough')]
    [string]$BackendAuth,

    [switch]$Show,
    [string]$OutputsFile
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $OutputsFile) { $OutputsFile = Join-Path $repoRoot '.deployment-outputs.json' }
if (-not (Test-Path $OutputsFile)) { throw "Deployment outputs not found at $OutputsFile. Run ./scripts/deploy.ps1 first." }
$o = Get-Content $OutputsFile -Raw | ConvertFrom-Json
if (-not $o.apimName) { throw 'No API Management instance in the outputs. Redeploy with deployGateway = true.' }

$subId = az account show --query id -o tsv
$base = "/subscriptions/$subId/resourceGroups/$($o.resourceGroupName)/providers/Microsoft.ApiManagement/service/$($o.apimName)/namedValues"
$apiVersion = '2024-05-01'

function Get-NamedValue([string]$name) {
    az rest --method get --uri "$base/$name`?api-version=$apiVersion" --query properties.value -o tsv 2>$null
}

function Set-NamedValue([string]$name, [string]$value) {
    $body = @{ properties = @{ displayName = $name; value = $value; secret = $false } } | ConvertTo-Json -Depth 5 -Compress
    $tmp = New-TemporaryFile
    Set-Content -Path $tmp -Value $body -Encoding utf8
    az rest --method put --uri "$base/$name`?api-version=$apiVersion" --body "@$tmp" --headers 'Content-Type=application/json' -o none
    $ok = ($LASTEXITCODE -eq 0)
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    if (-not $ok) { throw "Failed to update named value '$name'." }
}

if ($Show -or (-not $ClientAuth -and -not $BackendAuth)) {
    Write-Host ''
    Write-Host 'Current gateway authentication topology' -ForegroundColor Cyan
    '{0,-22} {1}' -f 'client-auth-mode:', (Get-NamedValue 'client-auth-mode')
    '{0,-22} {1}' -f 'backend-auth-mode:', (Get-NamedValue 'backend-auth-mode')
    '{0,-22} {1}' -f 'entra-audience:', (Get-NamedValue 'entra-audience')
    '{0,-22} {1}' -f 'entra-tenant-id:', (Get-NamedValue 'entra-tenant-id')
    Write-Host ''
    return
}

if ($ClientAuth) {
    Set-NamedValue 'client-auth-mode' $ClientAuth
    Write-Host "client-auth-mode  -> $ClientAuth" -ForegroundColor Green
}
if ($BackendAuth) {
    Set-NamedValue 'backend-auth-mode' $BackendAuth
    Write-Host "backend-auth-mode -> $BackendAuth" -ForegroundColor Green
    if ($BackendAuth -eq 'passthrough') {
        Write-Host 'Note: passthrough requires callers to present an Entra token; API-Management-subscription-key-only callers will now get 401 from Foundry.' -ForegroundColor Yellow
    }
}
Write-Host ''
Write-Host 'Changes apply to the next request. No redeployment needed.' -ForegroundColor Cyan
