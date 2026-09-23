<#
.SYNOPSIS
    Proves the three native API Management AI policies on the gateway.

.DESCRIPTION
    scripts/Test-Guardrails.ps1 answers "does the gateway block harmful
    prompts". This script answers the questions that are specific to running
    those checks natively rather than by hand, and each test exists because a
    real behaviour was measured rather than assumed:

      CONTENT SAFETY   llm-content-safety, including the two payload shapes that
                       break it when used unguarded - "system" sent as an array
                       of content blocks, which the policy silently skips, and
                       bodies over the fixed 10,000 character prompt window,
                       which it rejects outright with a 403.

      TOKEN METRICS    llm-emit-token-metric and llm-token-limit, verified from
                       the consumption headers the gateway returns.

      SEMANTIC CACHE   llm-semantic-cache-lookup and llm-semantic-cache-store,
                       verified by latency collapse on a repeated prompt.

    Every harmful string lives in scripts/guardrail-prompts.json, not here.

.PARAMETER Only
    Run a single section: ContentSafety, Tokens or Cache.

.EXAMPLE
    .\scripts\Test-NativePolicies.ps1

.EXAMPLE
    .\scripts\Test-NativePolicies.ps1 -Only Cache -ShowDetail
#>
[CmdletBinding()]
param(
    [ValidateSet('All', 'ContentSafety', 'Tokens', 'Cache')]
    [string]$Only = 'All',

    [string]$Model,

    [switch]$ShowDetail,

    [string]$OutputsFile,

    [string]$CorpusFile
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

if (-not $OutputsFile) { $OutputsFile = Join-Path $root '.deployment-outputs.json' }
if (-not (Test-Path $OutputsFile)) { throw "Deployment outputs not found at $OutputsFile. Run scripts/deploy.ps1 first." }
$o = Get-Content $OutputsFile -Raw | ConvertFrom-Json

if (-not $CorpusFile) { $CorpusFile = Join-Path $PSScriptRoot 'guardrail-prompts.json' }
$corpus = Get-Content $CorpusFile -Raw | ConvertFrom-Json

if (-not $Model) { $Model = $o.haikuDeploymentName }
if (-not $Model) { throw 'No model deployment found in the outputs. Pass -Model explicitly.' }

$base = "https://$($o.apimName).azure-api.net/anthropic"

# -- Credentials --------------------------------------------------------------

$subId = az account show --query id -o tsv
$listUri = "/subscriptions/$subId/resourceGroups/$($o.resourceGroupName)" +
"/providers/Microsoft.ApiManagement/service/$($o.apimName)" +
"/subscriptions/$($o.gatewaySubscriptionName)/listSecrets?api-version=2024-05-01"
$key = az rest --method post --uri $listUri --query primaryKey -o tsv
if ($LASTEXITCODE -ne 0 -or -not $key) { throw 'Could not read the API Management subscription key.' }

$headerName = if ($o.gatewaySubscriptionKeyHeader) { $o.gatewaySubscriptionKeyHeader } else { 'api-key' }
$headers = @{ 'anthropic-version' = '2023-06-01'; $headerName = $key }

function Get-Prompt {
    param([string]$Id)
    $p = $corpus.prompts | Where-Object { $_.id -eq $Id }
    if (-not $p) { throw "Prompt '$Id' not found in $CorpusFile." }
    return $p.prompt
}

# Header access differs between Windows PowerShell 5.1 and PowerShell 7+.
function Get-Header {
    param($Response, [string]$Name)
    if (-not $Response) { return $null }
    try {
        $h = $Response.Headers
        if ($null -eq $h) { return $null }

        # Error responses on 5.1 carry a WebHeaderCollection.
        if ($h -is [System.Net.WebHeaderCollection]) { return $h[$Name] }

        # PowerShell 7 exposes HttpHeaders, which is keyed but needs TryGetValues.
        if ($h.PSObject.Methods.Name -contains 'TryGetValues') {
            $v = $null
            if ($h.TryGetValues($Name, [ref]$v)) { return ($v -join ',') }
            return $null
        }

        # Windows PowerShell 5.1 with -UseBasicParsing hands back
        # Dictionary[string,string[]], so the value is an array, not a string.
        # Matching on the closed Dictionary[string,string] type misses it and
        # silently blanks every custom header, so match on shape instead.
        foreach ($k in $h.Keys) {
            if ($k -ieq $Name) {
                $val = $h[$k]
                if ($val -is [array]) { return ($val -join ',') }
                return $val
            }
        }
    }
    catch { return $null }
    return $null
}

# Returns status, elapsed milliseconds and the response headers for one call.
function Invoke-Gateway {
    param([hashtable]$Body, [string]$CacheScope)

    $json = $Body | ConvertTo-Json -Depth 20 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $sw = [Diagnostics.Stopwatch]::StartNew()

    $h = $headers
    if ($CacheScope) {
        $h = @{}
        foreach ($k in $headers.Keys) { $h[$k] = $headers[$k] }
        $h['x-gateway-cache-scope'] = $CacheScope
    }

    try {
        $r = Invoke-WebRequest -Uri "$base/v1/messages" -Method Post -Headers $h `
            -ContentType 'application/json' -TimeoutSec 240 -UseBasicParsing -Body $bytes
        $sw.Stop()
        return [pscustomobject]@{
            status     = [int]$r.StatusCode
            ms         = [int]$sw.ElapsedMilliseconds
            bodyChars  = $json.Length
            guardrail  = Get-Header -Response $r -Name 'x-guardrail'
            tokensUsed = Get-Header -Response $r -Name 'x-gateway-tokens-consumed'
            tokensLeft = Get-Header -Response $r -Name 'x-gateway-tokens-remaining'
            raw        = $r.Content
        }
    }
    catch {
        $sw.Stop()
        $resp = $_.Exception.Response
        return [pscustomobject]@{
            status     = if ($resp) { [int]$resp.StatusCode } else { 0 }
            ms         = [int]$sw.ElapsedMilliseconds
            bodyChars  = $json.Length
            guardrail  = Get-Header -Response $resp -Name 'x-guardrail'
            tokensUsed = $null
            tokensLeft = $null
            raw        = if ($_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { '' }
        }
    }
}

$results = New-Object System.Collections.Generic.List[object]

function Add-Result {
    param([string]$Section, [string]$Name, [bool]$Pass, [string]$Detail)
    $results.Add([pscustomobject]@{ section = $Section; name = $Name; pass = $Pass; detail = $Detail })
    $colour = if ($Pass) { 'Green' } else { 'Red' }
    $mark = if ($Pass) { 'PASS' } else { 'FAIL' }
    Write-Host ("  {0,-4} {1,-46} {2}" -f $mark, $Name, $Detail) -ForegroundColor $colour
}

Write-Host ''
Write-Host ('=' * 78)
Write-Host " NATIVE API MANAGEMENT AI POLICIES"
Write-Host ('=' * 78)
Write-Host " Gateway : $base"
Write-Host " Model   : $Model"
Write-Host ''

# -- 1. Content safety --------------------------------------------------------

if ($Only -in @('All', 'ContentSafety')) {
    Write-Host ' llm-content-safety' -ForegroundColor Cyan
    Write-Host (' ' + ('-' * 76))

    $harmful = Get-Prompt -Id 'harm-violence'
    $jailbreak = Get-Prompt -Id 'jailbreak-dan'
    $benign = Get-Prompt -Id 'control-general'

    # Baseline: the simplest possible shape.
    $r = Invoke-Gateway @{ model = $Model; max_tokens = 64; messages = @(@{ role = 'user'; content = $harmful }) }
    Add-Result 'ContentSafety' 'harmful prompt, string content' ($r.status -eq 403) "HTTP $($r.status)"

    $r = Invoke-Gateway @{ model = $Model; max_tokens = 64; messages = @(@{ role = 'user'; content = $jailbreak }) }
    Add-Result 'ContentSafety' 'jailbreak prompt, string content' ($r.status -eq 403) "HTTP $($r.status)"

    $r = Invoke-Gateway @{ model = $Model; max_tokens = 64; messages = @(@{ role = 'user'; content = $benign }) }
    Add-Result 'ContentSafety' 'benign prompt allowed' ($r.status -eq 200) "HTTP $($r.status), x-guardrail=$($r.guardrail)"

    # THE REGRESSION TEST. Unguarded, the native policy skips inspection entirely
    # when "system" is an array of content blocks - the shape Claude Desktop and
    # Claude Code send. A 200 here means the normalisation shim has stopped
    # working and the guardrail is bypassable by any real client.
    $r = Invoke-Gateway @{
        model      = $Model
        max_tokens = 64
        system     = @(@{ type = 'text'; text = 'You are a helpful coding assistant.' })
        messages   = @(@{ role = 'user'; content = $harmful })
    }
    Add-Result 'ContentSafety' 'harmful with system AS ARRAY (Claude app shape)' ($r.status -eq 403) "HTTP $($r.status)"

    $r = Invoke-Gateway @{
        model      = $Model
        max_tokens = 64
        system     = @(@{ type = 'text'; text = 'You are a helpful coding assistant.' })
        messages   = @(
            @{ role = 'user'; content = @(@{ type = 'text'; text = 'Hi' }) },
            @{ role = 'assistant'; content = @(@{ type = 'text'; text = 'Hello, how can I help?' }) },
            @{ role = 'user'; content = @(@{ type = 'text'; text = $harmful }) }
        )
    }
    Add-Result 'ContentSafety' 'harmful in multi-turn block array' ($r.status -eq 403) "HTTP $($r.status)"

    # Over the fixed 10,000 character prompt window. Unguarded this is a 403
    # regardless of content, which would break every real Claude Code request.
    $filler = ('The quick brown fox jumps over the lazy dog. ' * 320)
    $bigBenign = "Here is a long document to summarise.`n$filler`nPlease summarise it in one sentence."
    $r = Invoke-Gateway @{ model = $Model; max_tokens = 64; messages = @(@{ role = 'user'; content = $bigBenign }) }
    Add-Result 'ContentSafety' "benign prompt over 10k chars ($($bigBenign.Length) chars)" ($r.status -eq 200) "HTTP $($r.status), body=$($r.bodyChars) chars"

    # Same size, but harmful content inside the sampled head region.
    $bigHarmful = "$harmful`n$filler"
    $r = Invoke-Gateway @{ model = $Model; max_tokens = 64; messages = @(@{ role = 'user'; content = $bigHarmful }) }
    Add-Result 'ContentSafety' "harmful over 10k chars, in sampled region" ($r.status -eq 403) "HTTP $($r.status), body=$($r.bodyChars) chars"

    # Claude Code always sends tool definitions; make sure they do not break parsing.
    $r = Invoke-Gateway @{
        model      = $Model
        max_tokens = 64
        system     = @(@{ type = 'text'; text = 'You are a coding agent.' })
        tools      = @(@{ name = 'read_file'; description = 'Read a file'; input_schema = @{ type = 'object'; properties = @{ path = @{ type = 'string' } } } })
        messages   = @(@{ role = 'user'; content = @(@{ type = 'text'; text = $harmful }) })
    }
    Add-Result 'ContentSafety' 'harmful with tools defined' ($r.status -eq 403) "HTTP $($r.status)"
    Write-Host ''
}

# -- 2. Token metrics ---------------------------------------------------------

if ($Only -in @('All', 'Tokens')) {
    Write-Host ' llm-emit-token-metric and llm-token-limit' -ForegroundColor Cyan
    Write-Host (' ' + ('-' * 76))

    # A cold cache partition for this run. A nonce *inside the prompt* does not
    # work: the lookup is semantic, so the embedding ignores a random GUID and
    # the request is still served from cache, legitimately reporting zero
    # consumption - correct behaviour, but useless for proving the counter.
    # x-gateway-cache-scope is a vary-by key, so a fresh value guarantees a miss.
    $scope = [Guid]::NewGuid().ToString('N')
    $r = Invoke-Gateway -CacheScope $scope -Body @{ model = $Model; max_tokens = 64; messages = @(@{ role = 'user'; content = 'Name three primary colours.' }) }
    $hasConsumed = -not [string]::IsNullOrWhiteSpace($r.tokensUsed)
    $hasRemaining = -not [string]::IsNullOrWhiteSpace($r.tokensLeft)

    Add-Result 'Tokens' 'request succeeded' ($r.status -eq 200) "HTTP $($r.status)"
    Add-Result 'Tokens' 'x-gateway-tokens-consumed present' $hasConsumed "value=$($r.tokensUsed)"
    Add-Result 'Tokens' 'x-gateway-tokens-remaining present' $hasRemaining "value=$($r.tokensLeft)"

    # llm-token-limit uses a *renewing* per-minute window, so "remaining" can
    # legitimately go up between two calls when the window rolls over. What
    # proves the policy is counting real usage is that consumption is non-zero
    # and the remaining budget sits below the configured ceiling.
    $r2 = Invoke-Gateway -CacheScope ([Guid]::NewGuid().ToString('N')) -Body @{ model = $Model; max_tokens = 64; messages = @(@{ role = 'user'; content = 'Name three primary colours, then explain why in two sentences.' }) }
    $limit = if ($o.gatewayTokensPerMinute) { [int]$o.gatewayTokensPerMinute } else { 20000 }
    $counting = $false
    if ($hasConsumed -and $hasRemaining) {
        $counting = ([int]$r.tokensUsed -gt 0 -and [int]$r.tokensLeft -lt $limit -and [int]$r2.tokensLeft -lt $limit)
    }
    Add-Result 'Tokens' 'budget reflects real consumption' $counting "consumed=$($r.tokensUsed), remaining $($r.tokensLeft) then $($r2.tokensLeft), ceiling $limit"
    Write-Host ''
}

# -- 3. Semantic cache --------------------------------------------------------

if ($Only -in @('All', 'Cache')) {
    Write-Host ' llm-semantic-cache-lookup and llm-semantic-cache-store' -ForegroundColor Cyan
    Write-Host (' ' + ('-' * 76))

    if (-not $o.gatewaySemanticCacheEnabled) {
        Write-Host '  SKIP semantic cache is not enabled in this deployment' -ForegroundColor DarkYellow
    }
    else {
        # A cold cache partition, so a previous run cannot supply the hit. All
        # four calls below share it, so hits within this run still work. Note a
        # nonce in the prompt text would NOT give a cold start - the lookup is
        # semantic and the embedding ignores a random token.
        $scope = [Guid]::NewGuid().ToString('N')
        $prompt = 'In exactly one sentence, describe what a widget assembly line does.'

        $first = Invoke-Gateway -CacheScope $scope -Body @{ model = $Model; max_tokens = 128; messages = @(@{ role = 'user'; content = $prompt }) }
        Add-Result 'Cache' 'first call reaches the model' ($first.status -eq 200) "HTTP $($first.status), $($first.ms) ms"

        # The store happens on the way out; give it a moment to land in Redis.
        Start-Sleep -Seconds 3

        # Latency is a hint, not proof - a warm backend can be fast too. A cache
        # hit replays the *stored* completion, so the body is byte-identical,
        # which a non-deterministic model will not reproduce by chance.
        function Get-Text {
            param($Response)
            try { return (($Response.raw | ConvertFrom-Json).content | ForEach-Object { $_.text }) -join '' }
            catch { return '' }
        }
        $firstText = Get-Text $first

        $second = Invoke-Gateway -CacheScope $scope -Body @{ model = $Model; max_tokens = 128; messages = @(@{ role = 'user'; content = $prompt }) }
        $hit = ($second.status -eq 200 -and (Get-Text $second) -eq $firstText -and $firstText -ne '')
        Add-Result 'Cache' 'identical prompt served from cache' $hit "$($first.ms) ms -> $($second.ms) ms, body identical=$hit"

        # The point of a SEMANTIC cache: a reworded question should still hit.
        $reworded = 'In one sentence, what does a widget assembly line do?'
        $third = Invoke-Gateway -CacheScope $scope -Body @{ model = $Model; max_tokens = 128; messages = @(@{ role = 'user'; content = $reworded }) }
        $semanticHit = ($third.status -eq 200 -and (Get-Text $third) -eq $firstText -and $firstText -ne '')
        Add-Result 'Cache' 'reworded prompt served from cache' $semanticHit "$($first.ms) ms -> $($third.ms) ms, body identical=$semanticHit"

        # An unrelated prompt must miss, or the threshold is too loose and the
        # gateway is answering questions nobody asked.
        $other = Invoke-Gateway -CacheScope $scope -Body @{ model = $Model; max_tokens = 128; messages = @(@{ role = 'user'; content = 'What is the boiling point of water at sea level?' }) }
        $missed = ($other.status -eq 200 -and (Get-Text $other) -ne $firstText)
        Add-Result 'Cache' 'unrelated prompt is a cache miss' $missed "$($other.ms) ms, distinct answer=$missed"
    }
    Write-Host ''
}

# -- Result -------------------------------------------------------------------

$failed = @($results | Where-Object { -not $_.pass })
Write-Host ('=' * 78)
Write-Host ' RESULT'
Write-Host ('=' * 78)
Write-Host ''
foreach ($group in ($results | Group-Object section)) {
    $bad = @($group.Group | Where-Object { -not $_.pass }).Count
    $tone = if ($bad -eq 0) { 'Green' } else { 'Red' }
    Write-Host ("   {0,-16} {1} of {2} passed" -f $group.Name, ($group.Count - $bad), $group.Count) -ForegroundColor $tone
}
Write-Host ''

if ($ShowDetail) {
    $results | Format-Table section, name, pass, detail -AutoSize
}

if ($failed.Count -eq 0) {
    Write-Host ' PASS - every native policy behaved as expected.' -ForegroundColor Green
    exit 0
}

Write-Host " FAIL - $($failed.Count) check(s) did not pass:" -ForegroundColor Red
foreach ($f in $failed) { Write-Host "   $($f.section)/$($f.name): $($f.detail)" -ForegroundColor Red }
exit 1
