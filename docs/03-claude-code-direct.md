# 03 — Claude Code against Foundry, directly

This is the path where Claude Code (desktop app or CLI) talks straight to the Foundry Anthropic endpoint.

> **There is no interactive setup wizard for Foundry.** Unlike Amazon Bedrock and Google Vertex, `claude` offers no `/login` flow for Foundry. Configuration is environment variables only, and `/logout` is unavailable while in Foundry mode.

## The endpoint

```
https://<foundry-account>.services.ai.azure.com/anthropic/v1/messages
```

Claude Code builds this for you. Give it either:

- `ANTHROPIC_FOUNDRY_RESOURCE=<account-name>` — Claude Code appends `.services.ai.azure.com/anthropic`, **or**
- `ANTHROPIC_FOUNDRY_BASE_URL=https://<account>.services.ai.azure.com/anthropic` — you must include `/anthropic` yourself.

Set one or the other, never both.

## Minimum configuration

### PowerShell

```powershell
$env:CLAUDE_CODE_USE_FOUNDRY = '1'
$env:ANTHROPIC_FOUNDRY_RESOURCE = 'claudedemo-demo-abc123'

# Pin models to real deployment names. Do not skip this.
$env:ANTHROPIC_DEFAULT_SONNET_MODEL = 'claude-sonnet-4-6'
$env:ANTHROPIC_DEFAULT_HAIKU_MODEL  = 'claude-haiku-4-5'

az login          # supplies the credential
claude
```

### bash / zsh

```bash
export CLAUDE_CODE_USE_FOUNDRY=1
export ANTHROPIC_FOUNDRY_RESOURCE=claudedemo-demo-abc123
export ANTHROPIC_DEFAULT_SONNET_MODEL=claude-sonnet-4-6
export ANTHROPIC_DEFAULT_HAIKU_MODEL=claude-haiku-4-5

az login
claude
```

### Or just use the helper

```powershell
. ./scripts/Set-ClaudeCodeEnv.ps1 -Mode Direct -Auth Entra
```

```bash
source ./scripts/set-claude-code-env.sh direct entra
```

## Verifying it worked

Inside Claude Code, run `/status`. The **API provider** must read `Microsoft Foundry`. If it says `Anthropic API`, then `CLAUDE_CODE_USE_FOUNDRY` was not picked up — the desktop app inherits environment variables from the process that launched it, so a variable set after the app started will not apply.

Then ask it something trivial and confirm a reply comes back.

## Authentication options, in precedence order

Claude Code picks the first credential it finds:

| Priority | Variable | Credential | When to use |
| --- | --- | --- | --- |
| 1 | `ANTHROPIC_FOUNDRY_AUTH_TOKEN` | A bearer token you supply | A host application already holds a token; CI with a federated credential. Requires Claude Code **v2.1.203+**. |
| 2 | `ANTHROPIC_FOUNDRY_API_KEY` | Foundry account key | Fastest to demo; a long-lived shared secret, so least preferred. |
| 3 | *(nothing set)* | `DefaultAzureCredential` chain | **Recommended.** Uses `az login`, Managed Identity, Workload Identity, Visual Studio, etc. No secrets anywhere. |

Because a set key silently wins over the credential chain, always **unset** `ANTHROPIC_FOUNDRY_API_KEY` when demonstrating the Entra path. The helper scripts do this for you.

### Entra (recommended)

```powershell
Remove-Item Env:ANTHROPIC_FOUNDRY_API_KEY -ErrorAction SilentlyContinue
Remove-Item Env:ANTHROPIC_FOUNDRY_AUTH_TOKEN -ErrorAction SilentlyContinue
az login
claude
```

The caller needs the **`Cognitive Services User`** role on the Foundry account (role definition ID `a97b65f3-24c7-4388-baec-2e87135dc908`). `deploy.ps1 -GrantSelfAccess` assigns it. It is the least-privilege role that grants inference; `Cognitive Services Contributor` also works but additionally grants management-plane rights you do not need to call a model.

Verify your own access:

```powershell
az role assignment list --assignee $(az ad signed-in-user show --query id -o tsv) `
  --scope $(az cognitiveservices account show -n <account> -g <rg> --query id -o tsv) `
  --query "[].roleDefinitionName" -o tsv
```

### API key

```powershell
$env:ANTHROPIC_FOUNDRY_API_KEY = (az cognitiveservices account keys list `
  --name <account> --resource-group <rg> --query key1 -o tsv)
```

If `disableFoundryLocalAuth = true` was deployed, this returns a key that the service will refuse. That is the point of that switch — it proves the Entra path is genuinely keyless.

### Explicit bearer token

```powershell
$env:ANTHROPIC_FOUNDRY_AUTH_TOKEN = (az account get-access-token `
  --resource https://ai.azure.com --query accessToken -o tsv)
```

Tokens last roughly an hour and Claude Code will **not** refresh a static token. Prefer the credential chain for interactive use.

## Model pinning — read this before demoing

Claude Code's model aliases (`opus`, `sonnet`, `haiku`, and the internal fast model used for background tasks) map to Anthropic's current defaults, not to whatever you deployed. On Foundry:

- There is **no startup check** that the mapped models exist.
- A missing model surfaces as a runtime error partway through a conversation, typically as a 404 that looks like an endpoint problem.

So pin all three:

```powershell
$env:ANTHROPIC_DEFAULT_OPUS_MODEL   = 'claude-opus-4-6'      # only if deployed
$env:ANTHROPIC_DEFAULT_SONNET_MODEL = 'claude-sonnet-4-6'
$env:ANTHROPIC_DEFAULT_HAIKU_MODEL  = 'claude-haiku-4-5'
```

The values are **Foundry deployment names**, which in this template default to matching the model IDs. If you renamed a deployment, use the new name. `.deployment-outputs.json` always carries the correct values.

If you did not deploy Opus, do not leave `ANTHROPIC_DEFAULT_OPUS_MODEL` pointing at it — either omit it and avoid `/model opus`, or point it at your Sonnet deployment so the alias degrades gracefully.

## Useful extras

| Variable | Effect |
| --- | --- |
| `ENABLE_PROMPT_CACHING_1H=1` | Opts into the 1-hour prompt cache TTL instead of 5 minutes. Meaningful cost saving on long agentic sessions. |
| `CLAUDE_CODE_MAX_OUTPUT_TOKENS` | Caps output tokens per request. |
| `MAX_THINKING_TOKENS` | Bounds extended-thinking budget. |
| `DISABLE_PROMPT_CACHING=1` | Turn caching off entirely to make token metrics easier to read during a demo. |

## Making it stick for the desktop app

The Claude Code desktop app reads environment variables from its launch environment. Setting them in a terminal after the app is running has no effect.

**Windows** — set them for the user so any newly launched process inherits them:

```powershell
[Environment]::SetEnvironmentVariable('CLAUDE_CODE_USE_FOUNDRY', '1', 'User')
[Environment]::SetEnvironmentVariable('ANTHROPIC_FOUNDRY_RESOURCE', 'claudedemo-demo-abc123', 'User')
[Environment]::SetEnvironmentVariable('ANTHROPIC_DEFAULT_SONNET_MODEL', 'claude-sonnet-4-6', 'User')
[Environment]::SetEnvironmentVariable('ANTHROPIC_DEFAULT_HAIKU_MODEL', 'claude-haiku-4-5', 'User')
```

Then fully quit and restart the app.

**macOS** — either add the exports to `~/.zprofile` and relaunch from a terminal (`open -a Claude`), or register them with `launchctl setenv` before starting the app:

```bash
launchctl setenv CLAUDE_CODE_USE_FOUNDRY 1
launchctl setenv ANTHROPIC_FOUNDRY_RESOURCE claudedemo-demo-abc123
```

**Project-scoped alternative** — a `.claude/settings.json` `env` block in the repository applies to Claude Code sessions opened in that folder, which is tidier for a demo repo:

```json
{
  "env": {
    "CLAUDE_CODE_USE_FOUNDRY": "1",
    "ANTHROPIC_FOUNDRY_RESOURCE": "claudedemo-demo-abc123",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "claude-sonnet-4-6",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "claude-haiku-4-5"
  }
}
```

Never put a key in a committed settings file — leave the credential to `az login`.

## Claude Desktop — the standalone app

Claude Desktop is a different client from the Claude Code CLI. It ignores `ANTHROPIC_*` environment variables entirely and reads its own settings, either from a managed-policy location or from the profile library the in-app **Settings → Foundry** pane writes.

### One command

```powershell
# Creates the Entra app registration if you don't already have one,
# writes .env, and applies it to the local profile library.
./scripts/New-ClaudeConfig.ps1 -Mode Direct -CreateAppRegistration -Apply
```

If the app registration already exists, pass it instead of creating a second one:

```powershell
./scripts/New-ClaudeConfig.ps1 -Mode Direct -ClientId <app-client-id> -Apply
```

That does three things:

1. reads `.deployment-outputs.json` and writes an annotated `.env` (gitignored — see `.env.example` for the committed reference),
2. applies those values to the active Claude Desktop profile,
3. exports `out/claude-desktop-foundry.reg`, `out/com.anthropic.claudefordesktop.plist` and `out/claude-desktop-managed-settings.json` for fleet rollout.

**Claude Desktop reads configuration once, at launch.** Quit it completely — including the system tray icon — and reopen it.

### The settings, and what each one is

| Setting | Value | Notes |
|---|---|---|
| `inferenceProvider` | `foundry` | Setting this activates third-party mode |
| `inferenceCredentialKind` | `interactive` | Entra sign-in. When set, there is no fallback to any other credential |
| `inferenceFoundryResource` | `claudedemo-demo-abc123` | Resource **name** only — the app builds the URL |
| `inferenceFoundryTenantId` | directory (tenant) ID | |
| `inferenceFoundryClientId` | **application (client) ID** | Not the tenant ID — see below |
| `inferenceFoundryAuthFlow` | `browser` | or `device-code` / `broker` |
| `inferenceSessionLifetimeSec` | `86400` | Bounded by your own IdP session policy |
| `inferenceModels` | JSON array | `name` is the Foundry **deployment name**; first entry is the default |
| `modelDiscoveryEnabled` | `false` | Foundry has no Anthropic model-listing endpoint, so the list above is authoritative |

> **The client ID trap.** Anthropic's own documentation screenshot shows a tenant ID typed into the *Client ID* box. That fails with `AADSTS700016 — Application not found in the directory`. The two fields take different GUIDs. `Set-ClaudeDesktopConfig.ps1` refuses to write a config where they match.

### The app registration

Claude Desktop signs the user in with a **public client** app registration that holds a delegated permission on Azure Cognitive Services. `scripts/New-FoundryAppRegistration.ps1` creates it and is idempotent:

```powershell
./scripts/New-FoundryAppRegistration.ps1
```

It configures:

- `isFallbackPublicClient = true` (required for device-code and for any flow without a secret),
- delegated `user_impersonation` on resource app `7d312290-28c8-473c-a0ed-8e53749b6d6d` (Azure Cognitive Services),
- three redirect URIs, one per supported flow:

| Flow | Redirect URI |
|---|---|
| `browser` | `http://127.0.0.1/callback` |
| `broker` | `ms-appx-web://Microsoft.AAD.BrokerPlugin/{clientId}` and `msauth.com.anthropic.claudefordesktop://auth` |
| `device-code` | none needed |

Entra wildcards the **port** of a `127.0.0.1` redirect but not the **path**. A bare `http://127.0.0.1` fails with `AADSTS50011`.

`user_impersonation` on Cognitive Services is a *user-consentable* scope, so an ordinary user can complete the sign-in themselves. `-GrantAdminConsent` is available but optional, and will fail harmlessly if you are not a directory admin.

Sign-in only gets the user a token. Calling the model still requires the **Cognitive Services User** role on the Foundry account — `deploy.ps1 -GrantSelfAccess` grants it to you; grant it to the demo audience separately.

### Rolling it out to a fleet

Two placement options, both exported to `out/` by the script above:

- **Managed policy** — `HKCU\SOFTWARE\Policies\Anthropic\Claude` or `HKLM\...`, or the macOS plist. Use `-ApplyTarget Policy`.
- **Local profile** — the per-user profile library. This is the default, and needs no elevation.

Windows specifics that will cost you an afternoon otherwise:

- `HKCU\SOFTWARE\Policies` is ACL'd read-only for standard users, so the *policy* path needs elevation in **both** hives.
- Values must be `REG_SZ` placed **directly under** the key. Subkeys are ignored. `REG_EXPAND_SZ` reads as "present but unreadable"; `REG_QWORD`, `REG_MULTI_SZ` and `REG_BINARY` are invisible.
- If an HKLM policy exists, HKCU is ignored **entirely** — not merged.
- Under policy, every value is a string, including numbers and booleans. In the local profile library they are native JSON types. The scripts handle this difference for you.

## Same thing from the SDK

```python
from anthropic import AnthropicFoundry
from azure.identity import DefaultAzureCredential, get_bearer_token_provider

client = AnthropicFoundry(
    base_url="https://claudedemo-demo-abc123.services.ai.azure.com/anthropic",
    azure_ad_token_provider=get_bearer_token_provider(
        DefaultAzureCredential(), "https://ai.azure.com/.default"
    ),
)

msg = client.messages.create(
    model="claude-sonnet-4-6",      # the DEPLOYMENT name
    max_tokens=512,
    messages=[{"role": "user", "content": "Hello"}],
)
```

Runnable version: `samples/python/hello_claude.py --path direct --auth entra`.

## What this path cannot do

Worth stating out loud during a demo, because it motivates part two:

- No cross-user or cross-team quota — Foundry capacity is shared first-come-first-served.
- No per-caller cost attribution beyond what you can reconstruct from resource logs.
- No central place to add retries, failover, content filtering or prompt inspection.
- Every developer needs a direct RBAC assignment on the Foundry account.

Continue to [04 — Claude Code via the AI gateway](04-claude-code-gateway.md).
