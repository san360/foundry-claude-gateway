<#
.SYNOPSIS
    Applies the .env produced by New-ClaudeConfig.ps1 to Claude Desktop, and
    optionally to Claude Code.

.DESCRIPTION
    Claude Desktop never reads .env directly. It reads either a local saved
    configuration or a managed (MDM) policy, and this script translates .env
    into whichever you ask for.

      -Target Local   (default, no elevation)
                      %LOCALAPPDATA%\Claude-3p\configLibrary\<id>.json plus an
                      updated _meta.json marking it active. Same store the
                      in-app settings pane writes, so the values show up in the
                      UI. Values keep their NATIVE JSON types here.

      -Target Policy  (requires elevation)
                      HKCU or HKLM \SOFTWARE\Policies\Claude. This is the
                      fleet-deployment path. Note that Windows protects the
                      HKCU\SOFTWARE\Policies subtree - a standard user has
                      read-only access - so even -Scope User needs an elevated
                      shell here.

    Three details decide whether a policy is actually seen:

      1. Values must sit DIRECTLY under the policy key. Claude never reads
         subkeys, so a nested "inference" key is silently ignored.
      2. Values must be REG_SZ - including booleans and integers, written as
         "true" and "86400". REG_EXPAND_SZ registers as "policy present" but
         unreadable, which is worse than absent. REG_QWORD, REG_MULTI_SZ and
         REG_BINARY are invisible.
      3. When an HKLM policy exists, HKCU is ignored ENTIRELY - they are not
         merged. The script warns when it detects this.

    Either way the configuration is read once at launch, so Claude Desktop must
    be fully quit and reopened.

.PARAMETER ProfileName
    Name of the entry in the local config library. Reused across runs so the
    same profile is updated rather than duplicated.

.PARAMETER IncludeClaudeCode
    Also persist the CLAUDE_CODE_* / ANTHROPIC_* variables as user environment
    variables so the Claude Code CLI picks them up in new terminals.

.PARAMETER WhatIfOnly
    Export the payloads and show what would change, but write nothing.

.EXAMPLE
    ./scripts/Set-ClaudeDesktopConfig.ps1
    ./scripts/Set-ClaudeDesktopConfig.ps1 -IncludeClaudeCode
    ./scripts/Set-ClaudeDesktopConfig.ps1 -Target Policy -Scope Machine
#>
[CmdletBinding()]
param(
    [string]$EnvFile,

    [ValidateSet('Local', 'Policy')]
    [string]$Target = 'Local',

    [ValidateSet('User', 'Machine')]
    [string]$Scope = 'User',

    [string]$ProfileName = 'Foundry',

    [switch]$IncludeClaudeCode,

    [switch]$WhatIfOnly
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $EnvFile) { $EnvFile = Join-Path $repoRoot '.env' }
if (-not (Test-Path $EnvFile)) {
    throw "$EnvFile not found. Run ./scripts/New-ClaudeConfig.ps1 first."
}

# --- parse .env -----------------------------------------------------------

$settings = [ordered]@{}
foreach ($line in Get-Content $EnvFile) {
    $trimmed = $line.Trim()
    if (-not $trimmed -or $trimmed.StartsWith('#')) { continue }
    $split = $trimmed.IndexOf('=')
    if ($split -lt 1) { continue }

    $key = $trimmed.Substring(0, $split).Trim()
    $value = $trimmed.Substring($split + 1).Trim()

    if ($value.Length -ge 2 -and $value.StartsWith('"') -and $value.EndsWith('"')) {
        $value = $value.Substring(1, $value.Length - 2) -replace '\\"', '"' -replace '\\\\', '\'
    }
    $settings[$key] = $value
}

# Only these are client settings. The AZURE_* / FOUNDRY_* entries exist so a
# human can tell which deployment the file describes.
$integerKeys = @(
    'inferenceSessionLifetimeSec'
    'inferenceCredentialHelperTtlSec'
    'inferenceCredentialHelperTimeoutSec'
)
$booleanKeys = @(
    'modelDiscoveryEnabled'
    'modelPrefer1mContext'
    'inferenceCredentialHelperSilentRefreshEnabled'
)
$jsonKeys = @(
    'inferenceModels'
    'inferenceCustomHeaders'
    'inferenceGatewayOidc'
)
$stringKeys = @(
    'inferenceProvider'
    'inferenceCredentialKind'
    'inferenceFoundryResource'
    'inferenceFoundryTenantId'
    'inferenceFoundryClientId'
    'inferenceFoundryAuthFlow'
    'inferenceFoundryApiKey'
    'inferenceGatewayBaseUrl'
    'inferenceGatewayApiKey'
    'inferenceGatewayAuthScheme'
    'inferenceGatewayOidcAuthFlow'
    'inferenceCredentialHelper'
    'userContentRendererUrl'
)
$desktopKeys = $stringKeys + $integerKeys + $booleanKeys + $jsonKeys

$claudeCodeKeys = @(
    'CLAUDE_CODE_USE_FOUNDRY'
    'ANTHROPIC_FOUNDRY_RESOURCE'
    'ANTHROPIC_FOUNDRY_BASE_URL'
    'ANTHROPIC_FOUNDRY_API_KEY'
    'ANTHROPIC_FOUNDRY_AUTH_TOKEN'
    'ANTHROPIC_DEFAULT_SONNET_MODEL'
    'ANTHROPIC_DEFAULT_OPUS_MODEL'
    'ANTHROPIC_DEFAULT_HAIKU_MODEL'
)

$desktop = [ordered]@{}
foreach ($k in $desktopKeys) {
    # An empty value means "unset". Writing it would pin an empty string and
    # suppress the client's own default.
    if ($settings.Contains($k) -and $settings[$k] -ne '') { $desktop[$k] = $settings[$k] }
}
if ($desktop.Count -eq 0) { throw "No inference* settings found in $EnvFile." }

# --- sanity checks --------------------------------------------------------

if ($desktop['inferenceProvider'] -eq 'foundry' -and $desktop['inferenceCredentialKind'] -eq 'interactive') {
    $clientId = $desktop['inferenceFoundryClientId']
    $tenantId = $desktop['inferenceFoundryTenantId']
    if (-not $clientId) {
        throw 'Interactive sign-in selected but inferenceFoundryClientId is empty. Run New-FoundryAppRegistration.ps1.'
    }
    if ($clientId -eq $tenantId) {
        throw @'
inferenceFoundryClientId is set to the tenant ID. They are different objects:
the client ID identifies the app registration, the tenant ID identifies the
directory. Sign-in would fail with AADSTS700016. Run:

    ./scripts/New-FoundryAppRegistration.ps1
'@
    }
}

# --- typed payload for the local config library ---------------------------

# The local library stores native JSON types, unlike the policy hive where
# everything is a string. Nested JSON is injected verbatim via placeholders:
# round-tripping it through ConvertFrom-Json/ConvertTo-Json on Windows
# PowerShell 5.1 rewrites arrays into {"value":[...],"Count":n}.
$jsonPlaceholders = @{}
$typed = [ordered]@{}
foreach ($k in $desktop.Keys) {
    $raw = $desktop[$k]
    if ($integerKeys -contains $k) { $typed[$k] = [int64]$raw }
    elseif ($booleanKeys -contains $k) { $typed[$k] = ($raw -match '^(?i:true|1|yes)$') }
    elseif ($jsonKeys -contains $k) {
        $token = "__RAWJSON_${k}__"
        $jsonPlaceholders[$token] = $raw
        $typed[$k] = $token
    }
    else { $typed[$k] = $raw }
}

function ConvertTo-ClaudeJson {
    param($Payload)
    $json = $Payload | ConvertTo-Json -Depth 8
    foreach ($token in $jsonPlaceholders.Keys) {
        $json = $json.Replace('"' + $token + '"', $jsonPlaceholders[$token])
    }
    return $json
}

$outDir = Join-Path $repoRoot 'out'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

# Always export the portable payloads, so the same configuration can be handed
# to Intune, Group Policy, or a macOS/Linux machine without rerunning this.
$regLines = [System.Collections.Generic.List[string]]::new()
$regHive = if ($Scope -eq 'Machine') { 'HKEY_LOCAL_MACHINE' } else { 'HKEY_CURRENT_USER' }
$regLines.Add('Windows Registry Editor Version 5.00')
$regLines.Add('')
$regLines.Add("[$regHive\SOFTWARE\Policies\Claude]")
foreach ($k in $desktop.Keys) {
    $escaped = $desktop[$k] -replace '\\', '\\' -replace '"', '\"'
    $regLines.Add('"' + $k + '"="' + $escaped + '"')
}
$regFile = Join-Path $outDir 'claude-desktop-foundry.reg'
Set-Content -Path $regFile -Value $regLines -Encoding ascii

$jsonFile = Join-Path $outDir 'claude-desktop-managed-settings.json'
ConvertTo-ClaudeJson $typed | Set-Content $jsonFile -Encoding utf8

$plistLines = [System.Collections.Generic.List[string]]::new()
$plistLines.Add('<?xml version="1.0" encoding="UTF-8"?>')
$plistLines.Add('<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">')
$plistLines.Add('<plist version="1.0">')
$plistLines.Add('<dict>')
foreach ($k in $desktop.Keys) {
    $plistLines.Add("  <key>$k</key>")
    $plistLines.Add("  <string>$([System.Security.SecurityElement]::Escape($desktop[$k]))</string>")
}
$plistLines.Add('</dict>')
$plistLines.Add('</plist>')
$plistFile = Join-Path $outDir 'com.anthropic.claudefordesktop.plist'
Set-Content -Path $plistFile -Value $plistLines -Encoding utf8

Write-Host ''
Write-Host 'Settings to apply:'
foreach ($k in $desktop.Keys) {
    $shown = [string]$desktop[$k]
    if ($k -match 'ApiKey|Token') { $shown = '***' }
    if ($shown.Length -gt 68) { $shown = $shown.Substring(0, 65) + '...' }
    Write-Host ('  {0,-30} {1}' -f $k, $shown)
}
Write-Host ''
Write-Host "Exported  $regFile"
Write-Host "Exported  $plistFile"
Write-Host "Exported  $jsonFile"

if ($WhatIfOnly) {
    Write-Host ''
    Write-Host 'WhatIfOnly - nothing was applied.' -ForegroundColor Yellow
    return
}

$isWin = ($PSVersionTable.PSVersion.Major -lt 6) -or $IsWindows
if (-not $isWin) {
    Write-Host ''
    Write-Host 'Not running on Windows. Copy a payload into place:' -ForegroundColor Yellow
    Write-Host '  macOS local    ~/Library/Application Support/Claude-3p/configLibrary/'
    Write-Host '  macOS managed  /Library/Managed Preferences/<user>/com.anthropic.claudefordesktop.plist'
    Write-Host '  Linux managed  /etc/claude-desktop/managed-settings.json'
    return
}

if (Get-Process -Name 'Claude*' -ErrorAction SilentlyContinue) {
    Write-Host ''
    Write-Host 'Claude Desktop is running. It reads configuration only at launch, so quit it' -ForegroundColor Yellow
    Write-Host 'completely (system tray included) and reopen it after this finishes.' -ForegroundColor Yellow
}

if ($Target -eq 'Local') {
    # --- local config library ---------------------------------------------
    $libDir = Join-Path $env:LOCALAPPDATA 'Claude-3p\configLibrary'
    New-Item -ItemType Directory -Force -Path $libDir | Out-Null
    $metaPath = Join-Path $libDir '_meta.json'

    $entries = @()
    if (Test-Path $metaPath) {
        $meta = Get-Content $metaPath -Raw | ConvertFrom-Json
        if ($meta.entries) { $entries = @($meta.entries) }
    }

    # Update the entry with this name if it exists, so repeated runs converge
    # on one profile instead of littering the picker.
    $entry = $entries | Where-Object { $_.name -eq $ProfileName } | Select-Object -First 1
    if ($entry) {
        $id = $entry.id
    }
    else {
        $id = [guid]::NewGuid().ToString()
        $entries += [pscustomobject]@{ id = $id; name = $ProfileName }
    }

    ConvertTo-ClaudeJson $typed | Set-Content (Join-Path $libDir "$id.json") -Encoding utf8
    [ordered]@{ appliedId = $id; entries = $entries } |
        ConvertTo-Json -Depth 5 | Set-Content $metaPath -Encoding utf8

    Write-Host ''
    Write-Host "Applied $($typed.Count) settings to the '$ProfileName' profile" -ForegroundColor Green
    Write-Host "  $libDir\$id.json" -ForegroundColor DarkGray
}
else {
    # --- managed policy ---------------------------------------------------
    $psPath = if ($Scope -eq 'Machine') { 'HKLM:\SOFTWARE\Policies\Claude' } else { 'HKCU:\SOFTWARE\Policies\Claude' }

    if ($Scope -eq 'User' -and (Test-Path 'HKLM:\SOFTWARE\Policies\Claude')) {
        Write-Host ''
        Write-Host 'A machine-wide policy exists at HKLM\SOFTWARE\Policies\Claude.' -ForegroundColor Yellow
        Write-Host 'Claude ignores HKCU entirely when HKLM is present - they are not merged.' -ForegroundColor Yellow
        Write-Host 'Rerun with -Scope Machine for these settings to take effect.' -ForegroundColor Yellow
    }

    try {
        # Recreate the key so settings dropped since the last run actually
        # disappear instead of lingering from a different mode.
        if (Test-Path $psPath) { Remove-Item $psPath -Recurse -Force }
        New-Item -Path $psPath -Force | Out-Null
        foreach ($k in $desktop.Keys) {
            New-ItemProperty -Path $psPath -Name $k -Value ([string]$desktop[$k]) -PropertyType String -Force | Out-Null
        }
    }
    catch [System.UnauthorizedAccessException] {
        throw @"
Access denied writing $psPath.

Windows protects the SOFTWARE\Policies subtree in BOTH hives - a standard user
has read-only access even under HKCU - so managed policy always needs an
elevated shell. Either:

  * rerun this from an elevated PowerShell, or
  * import $regFile via Group Policy or Intune, or
  * use the non-elevated path instead:
        ./scripts/Set-ClaudeDesktopConfig.ps1 -Target Local
"@
    }

    Write-Host ''
    Write-Host "Applied $($desktop.Count) settings to $psPath" -ForegroundColor Green
}

if ($IncludeClaudeCode) {
    $applied = 0
    foreach ($k in $claudeCodeKeys) {
        $value = if ($settings.Contains($k) -and $settings[$k] -ne '') { $settings[$k] } else { $null }
        [Environment]::SetEnvironmentVariable($k, $value, 'User')
        if ($null -ne $value) { $applied++ }
    }
    Write-Host "Applied $applied Claude Code variables to the user environment" -ForegroundColor Green
    Write-Host 'Open a new terminal for them to take effect.' -ForegroundColor DarkGray
}

Write-Host ''
Write-Host 'Quit Claude Desktop completely and reopen it - configuration is read once at launch.' -ForegroundColor Cyan
