<#
.SYNOPSIS
  Populate .env with the values the http/*.http request files need.

.DESCRIPTION
  The .http files in http/ read their endpoint, token and keys through the REST
  Client extension's {{$dotenv KEY}} system variable, which resolves against the
  .env file at the repository root. This script writes the keys they expect.

  Two of those values are credentials and one of them expires:

    CONTENT_SAFETY_TOKEN     Entra access token for the Content Safety data
                             plane. Lives about 60-90 minutes. Re-run this
                             script when a request starts returning 401.
    GATEWAY_SUBSCRIPTION_KEY API Management subscription key for the gateway.
                             Stable until rotated.

  .env is gitignored, so both are safe to write there. Nothing here is written
  to a tracked file.

  Everything else is derived from .deployment-outputs.json, so this works
  against whichever environment you last deployed without any hand editing.

.PARAMETER EnvFile
  Path to the .env file to update. Defaults to the repository root.

.PARAMETER SkipGatewayKey
  Do not read the API Management subscription key. Use when you only want the
  Content Safety requests and would rather not touch APIM.

.PARAMETER SetProcessEnv
  Also set the values as environment variables in the current PowerShell
  session, for use from curl or Invoke-RestMethod rather than the .http files.

.EXAMPLE
  ./scripts/Set-HttpEnv.ps1
  Refresh every value, including a fresh Content Safety token.

.EXAMPLE
  ./scripts/Set-HttpEnv.ps1 -SetProcessEnv
  Same, and export them into the current session as well.
#>
[CmdletBinding()]
param(
    [string] $EnvFile,
    [switch] $SkipGatewayKey,
    [switch] $SetProcessEnv
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $EnvFile) { $EnvFile = Join-Path $repoRoot '.env' }
$outputsPath = Join-Path $repoRoot '.deployment-outputs.json'

if (-not (Test-Path $outputsPath)) {
    throw "No .deployment-outputs.json at $outputsPath. Run ./scripts/deploy.ps1 first."
}
$outputs = Get-Content $outputsPath -Raw | ConvertFrom-Json

# The native llm-content-safety policy only accepts the cognitiveservices.azure.com
# form, so use the same host here - the .http files then exercise exactly the
# endpoint the gateway calls rather than an alias of it.
$contentSafetyEndpoint = "https://$($outputs.foundryAccountName).cognitiveservices.azure.com"

Write-Host 'Requesting a Content Safety access token...' -ForegroundColor Cyan
$token = az account get-access-token --resource 'https://cognitiveservices.azure.com' --query accessToken -o tsv
if ($LASTEXITCODE -ne 0 -or -not $token) {
    throw 'Could not acquire a token. Run az login and select the right subscription.'
}

$values = [ordered]@{
    CONTENT_SAFETY_ENDPOINT    = $contentSafetyEndpoint
    CONTENT_SAFETY_API_VERSION = '2024-09-01'
    CONTENT_SAFETY_TOKEN       = $token
    CONTENT_SAFETY_BLOCKLIST   = if ($outputs.PSObject.Properties.Name -contains 'gatewayGuardrailBlocklistName' -and $outputs.gatewayGuardrailBlocklistName) {
                                     $outputs.gatewayGuardrailBlocklistName
                                 } else { 'claude-demo-selfharm' }
    GATEWAY_BASE_URL           = $outputs.gatewayAnthropicBaseUrl
    GATEWAY_KEY_HEADER         = $outputs.gatewaySubscriptionKeyHeader
    HAIKU_DEPLOYMENT           = $outputs.haikuDeploymentName
    SONNET_DEPLOYMENT          = $outputs.sonnetDeploymentName
}

if (-not $SkipGatewayKey) {
    Write-Host 'Reading the API Management subscription key...' -ForegroundColor Cyan
    $subId = az account show --query id -o tsv
    $uri = "/subscriptions/$subId/resourceGroups/$($outputs.resourceGroupName)" +
           "/providers/Microsoft.ApiManagement/service/$($outputs.apimName)" +
           "/subscriptions/$($outputs.gatewaySubscriptionName)/listSecrets?api-version=2024-05-01"
    $key = az rest --method post --uri $uri --query primaryKey -o tsv
    if ($LASTEXITCODE -eq 0 -and $key) {
        $values['GATEWAY_SUBSCRIPTION_KEY'] = $key
    } else {
        Write-Warning 'Could not read the subscription key. Gateway requests in http/ will return 401.'
    }
}

# Preserve whatever else is in .env - it also carries the Claude Desktop
# configuration - and replace only the keys this script owns.
$lines = if (Test-Path $EnvFile) { [IO.File]::ReadAllLines($EnvFile) } else { @() }
$result = [System.Collections.Generic.List[string]]::new()
$seen = @{}

foreach ($line in $lines) {
    if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=') {
        $key = $Matches[1]
        if ($values.Contains($key)) {
            $result.Add("$key=$($values[$key])")
            $seen[$key] = $true
            continue
        }
    }
    $result.Add($line)
}

$added = $values.Keys | Where-Object { -not $seen.ContainsKey($_) }
if ($added) {
    if ($result.Count -gt 0 -and $result[$result.Count - 1] -ne '') { $result.Add('') }
    $result.Add('# --- http/*.http request files (scripts/Set-HttpEnv.ps1) ---')
    $result.Add('# CONTENT_SAFETY_TOKEN expires in about an hour. Re-run the script on a 401.')
    foreach ($key in $added) { $result.Add("$key=$($values[$key])") }
}

# No BOM: other readers of .env treat a leading BOM as part of the first key.
[IO.File]::WriteAllLines($EnvFile, $result, [Text.UTF8Encoding]::new($false))

if ($SetProcessEnv) {
    foreach ($key in $values.Keys) { Set-Item -Path "env:$key" -Value $values[$key] }
}

Write-Host ''
Write-Host "Updated $EnvFile" -ForegroundColor Green
foreach ($key in $values.Keys) {
    $shown = if ($key -match '(TOKEN|SUBSCRIPTION_KEY)$') { "<set, $($values[$key].Length) chars>" } else { $values[$key] }
    '  {0,-26} {1}' -f $key, $shown
}
Write-Host ''
Write-Host 'Open http/content-safety.http and click Send Request above any block.' -ForegroundColor Cyan
if ($SetProcessEnv) { Write-Host 'Values are also exported into this session.' -ForegroundColor Cyan }
