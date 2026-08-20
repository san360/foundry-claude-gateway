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
