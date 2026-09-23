<#
.SYNOPSIS
    Creates or updates the Azure AI Content Safety blocklist the gateway enforces.

.DESCRIPTION
    Blocklists are a data-plane resource. ARM and Bicep cannot create them, so
    the policy references a blocklist by name and this script makes sure that
    name exists with the expected terms before the policy is applied.

    Why a blocklist exists at all: Content Safety scores some genuinely harmful
    prompts 0 in every harm category. First-person self-harm intent is the
    measured example - it returns SelfHarm severity 0 on EightSeverityLevels and
    Prompt Shield reports no attack - so no value of the severity threshold can
    block it. A blocklist is the documented control for exactly this gap.

    The script is idempotent. addOrUpdateBlocklistItems is keyed on the term
    text, so re-running converges rather than duplicating.

.PARAMETER Endpoint
    Content Safety endpoint. Defaults to contentSafetyEndpoint from
    .deployment-outputs.json.

.PARAMETER TermsFile
    JSON describing the blocklist and its terms. Defaults to
    scripts/content-safety-blocklist.json.

.PARAMETER Verify
    After writing, score each term through text:analyze and report whether the
    blocklist actually matches. Propagation takes a few seconds.

.EXAMPLE
    .\scripts\Set-ContentSafetyBlocklist.ps1 -Verify
#>
[CmdletBinding()]
param(
    [string]$Endpoint,
    [string]$TermsFile = (Join-Path $PSScriptRoot 'content-safety-blocklist.json'),
    [string]$OutputsFile = (Join-Path (Split-Path $PSScriptRoot -Parent) '.deployment-outputs.json'),
    [switch]$Verify
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $TermsFile)) { throw "Terms file not found: $TermsFile" }
$spec = Get-Content $TermsFile -Raw | ConvertFrom-Json

if (-not $Endpoint) {
    if (-not (Test-Path $OutputsFile)) {
        throw "No -Endpoint given and $OutputsFile does not exist. Deploy first, or pass -Endpoint."
    }
    $o = Get-Content $OutputsFile -Raw | ConvertFrom-Json
    # deploy.ps1 flattens ARM's { value = ... } wrapper, but tolerate both.
    $Endpoint = if ($o.contentSafetyEndpoint.value) { $o.contentSafetyEndpoint.value } else { $o.contentSafetyEndpoint }
}
if (-not $Endpoint) { throw 'Could not determine the Content Safety endpoint.' }
$Endpoint = $Endpoint.TrimEnd('/')

$token = az account get-access-token --resource https://cognitiveservices.azure.com --query accessToken -o tsv
if ($LASTEXITCODE -ne 0 -or -not $token) { throw 'Could not acquire a Cognitive Services token. Run az login.' }

$apiVersion = '2024-09-01'
$name = $spec.blocklistName
$tmp = [IO.Path]::GetTempPath()

function Invoke-ContentSafety {
    param([string]$Method, [string]$Uri, $Body, [string]$ContentType = 'application/json')

    $file = Join-Path $tmp ("cs-" + [Guid]::NewGuid().ToString('N') + '.json')
    try {
        # Write without a BOM: the service rejects a BOM-prefixed body.
        [IO.File]::WriteAllText($file, ($Body | ConvertTo-Json -Depth 8 -Compress), [Text.UTF8Encoding]::new($false))
        $raw = curl.exe -s -X $Method $Uri `
            -H "Authorization: Bearer $token" `
            -H "content-type: $ContentType" `
            --data "@$file" 2>&1
        if (-not $raw) { return $null }
        try { return ($raw | ConvertFrom-Json) } catch { throw "Unexpected response from $Uri : $raw" }
    }
    finally { Remove-Item $file -ErrorAction SilentlyContinue }
}

Write-Host ''
Write-Host " Content Safety : $Endpoint"
Write-Host " Blocklist      : $name"
Write-Host ''

$created = Invoke-ContentSafety -Method PATCH `
    -Uri "$Endpoint/contentsafety/text/blocklists/$name`?api-version=$apiVersion" `
    -ContentType 'application/merge-patch+json' `
    -Body @{ description = $spec.description }

if ($created.error) { throw "Could not create the blocklist: $($created.error.message)" }
Write-Host "  blocklist ready" -ForegroundColor Green

$items = @($spec.items | ForEach-Object { @{ text = $_.text; description = $_.description } })
$added = Invoke-ContentSafety -Method POST `
    -Uri "$Endpoint/contentsafety/text/blocklists/$name`:addOrUpdateBlocklistItems?api-version=$apiVersion" `
    -Body @{ blocklistItems = $items }

if ($added.error) { throw "Could not add blocklist items: $($added.error.message)" }
Write-Host "  $($added.blocklistItems.Count) term(s) present" -ForegroundColor Green

if ($Verify) {
    Write-Host ''
    Write-Host ' Verifying (propagation can take a few seconds)'
    Start-Sleep -Seconds 5
    $bad = 0
    foreach ($item in $spec.items) {
        $r = Invoke-ContentSafety -Method POST `
            -Uri "$Endpoint/contentsafety/text:analyze?api-version=$apiVersion" `
            -Body @{ text = $item.text; outputType = 'EightSeverityLevels'; blocklistNames = @($name); haltOnBlocklistHit = $true }
        $hit = $r.blocklistsMatch.Count -gt 0
        if (-not $hit) { $bad++ }
        $mark = if ($hit) { 'MATCH  ' } else { 'NO-HIT ' }
        $colour = if ($hit) { 'Green' } else { 'Red' }
        Write-Host ("  {0} {1}" -f $mark, $item.text) -ForegroundColor $colour
    }
    Write-Host ''
    if ($bad -gt 0) {
        Write-Warning "$bad term(s) did not match yet. Blocklist propagation is eventually consistent; re-run -Verify shortly."
    }
    else {
        Write-Host ' All terms match.' -ForegroundColor Green
    }
}

Write-Host ''
return [pscustomobject]@{
    Endpoint      = $Endpoint
    BlocklistName = $name
    TermCount     = $items.Count
}
