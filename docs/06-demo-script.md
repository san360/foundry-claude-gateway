# 06 — Demo script

A 20-minute run of show. Everything below has been rehearsed against the deployed template; timings assume the environment is already deployed and warm.

## Before you start

- [ ] Deployment finished; `.deployment-outputs.json` exists at the repo root.
- [ ] `az login` done, correct subscription selected.
- [ ] `./scripts/Test-ClaudeEndpoint.ps1 -Mode Direct -Auth Entra` passes.
- [ ] `./scripts/Test-ClaudeEndpoint.ps1 -Mode Gateway -Auth Entra` passes.
- [ ] `./scripts/Set-GatewayAuthMode.ps1 -ClientAuth either -BackendAuth managedIdentity`.
- [ ] Application Insights open in a browser tab, Logs blade ready.
- [ ] Foundry portal open on the deployments blade.
- [ ] Two terminals: one for `claude`, one for scripts.
- [ ] Font size up. Clear terminal history so the `/status` output is visible.

Warm the model with one throwaway request; first-token latency on a cold deployment makes the demo feel slow.

## Act 1 — Claude models in Foundry (3 min)

**Show the Foundry portal.** Deployments blade: Claude Haiku 4.5 and Sonnet 4.6, `GlobalStandard`, capacity in TPM.

> "These are Anthropic's Claude models running as first-party Foundry deployments. Same Azure resource model as any other Foundry model — RBAC, private networking, diagnostics, capacity management. Version 2 of the deployment means inference stays on Azure infrastructure."

**Show the endpoint shape:**

```
https://<account>.services.ai.azure.com/anthropic/v1/messages
```

> "That's the Anthropic Messages API, unmodified. Any Anthropic SDK, any Anthropic-compatible tool, points at this."

## Act 2 — Claude Code, direct, keyless (5 min)

```powershell
. ./scripts/Set-ClaudeCodeEnv.ps1 -Mode Direct -Auth Entra
```

Point out the printed summary: endpoint, credential = Microsoft Entra ID, pinned models.

> "Three things happened. `CLAUDE_CODE_USE_FOUNDRY=1` switches the provider. `ANTHROPIC_FOUNDRY_RESOURCE` names the account. And notice what is *not* set — there is no API key anywhere. Claude Code falls back to the Azure default credential chain, so it uses my `az login` session."

```powershell
claude
```

In the session:

```
/status
```

> "API provider: **Microsoft Foundry**. That is the confirmation."

Then a real task — open a file in the repo and ask for something substantive:

```
Read infra/policies/anthropic-api.xml and explain what the backend-auth-mode branch does.
```

> "This is the full Claude Code agentic experience — file reads, tool use, streaming — with inference served from my own Azure subscription, in my region, under my tenant's Conditional Access."

**The authorization point.** In a second terminal:

```powershell
az role assignment list `
  --assignee $(az ad signed-in-user show --query id -o tsv) `
  --scope $(az cognitiveservices account show -n <account> -g <rg> --query id -o tsv) `
  --query "[].roleDefinitionName" -o tsv
```

> "`Cognitive Services User`. Remove that assignment and I lose access in minutes — no key to rotate, no secret to chase."

Optionally show the token:

```powershell
az account get-access-token --resource https://ai.azure.com --query expiresOn -o tsv
```

> "Roughly one hour, refreshed automatically. That is the whole authentication story for the direct path."

## Act 3 — What direct cannot do (2 min)

Do not skip this; it is what earns the second half.

> "This is great for one developer. Now give it to two hundred. There is no per-team quota — first request wins the shared capacity. There is no per-developer cost attribution. There is no place to add content filtering, or failover to a second region, or a break-glass switch. And every one of those two hundred developers needs a direct role assignment on the model resource."

## Act 4 — The AI gateway (6 min)

```powershell
. ./scripts/Set-ClaudeCodeEnv.ps1 -Mode Gateway -Auth Entra
```

> "One variable changed: the base URL now points at API Management instead of Foundry. Same client, same API, same credential. Nothing else in my environment moved."

```powershell
./scripts/Test-ClaudeEndpoint.ps1 -Mode Gateway -Auth Entra
```

Point at the output:

```
x-gateway                  azure-api-management
x-gateway-tokens-remaining 18342
x-gateway-tokens-consumed  1658
```

> "`x-gateway` proves the hop. The token headers are the gateway telling me my remaining budget — it parsed the Anthropic response schema and did the accounting."

```powershell
claude
```

Run the same kind of task as Act 2. It behaves identically, including streaming.

> "Streaming still works, which matters — the policy sets `buffer-response=false`. That single attribute is the difference between a working gateway and one that looks hung."

**Now the governance layer.** In Application Insights → Logs:

```kusto
customMetrics
| where name in ("Prompt Tokens", "Completion Tokens", "Total Tokens")
| extend caller = tostring(customDimensions["CallerId"])
| summarize tokens = sum(value) by name, caller
| render columnchart
```

> "Token consumption per caller, emitted by the gateway. `CallerId` is the Entra object ID from the validated token. That is chargeback, and it is the thing you cannot get from the direct path."

Then:

```kusto
requests
| where name contains "messages"
| project timestamp, resultCode, duration, url
| order by timestamp desc
| take 20
```

> "Every request, latency, status. And with body logging on, the actual prompts — which is a governance capability and a privacy decision you should make deliberately."

## Act 5 — Auth topologies, live (3 min)

This is the strongest moment. Nothing is redeployed.

```powershell
./scripts/Set-GatewayAuthMode.ps1 -Show
```

> "Two named values drive the whole security posture."

**Switch to passthrough:**

```powershell
./scripts/Set-GatewayAuthMode.ps1 -BackendAuth passthrough
./scripts/Test-ClaudeEndpoint.ps1 -Mode Gateway -Auth Entra
```

> "Now the gateway validates my token and forwards it unchanged. Foundry evaluates RBAC against *me*, not the gateway. Per-user authorization, per-user audit in the Foundry resource log — and the gateway is still doing quota and metrics."

**Switch back:**

```powershell
./scripts/Set-GatewayAuthMode.ps1 -BackendAuth managedIdentity
```

> "And back to the gateway's own managed identity. Now clients cannot reach Foundry even if they wanted to — only the gateway identity has the role. That is what lets me turn Foundry's API keys off completely."

**Force a 429** if you set `gatewayTokensPerMinute` low for the demo:

```powershell
1..5 | ForEach-Object { ./scripts/Test-ClaudeEndpoint.ps1 -Mode Gateway -Auth Key }
```

> "429 with `Retry-After`. Per-caller, enforced at the edge, before the spend."

## Act 6 — Close (1 min)

| | Direct | Gateway |
| --- | --- | --- |
| Setup | 2 environment variables | 2 environment variables |
| Latency | lowest | one extra hop |
| Entra auth | ✓ | ✓ (two topologies) |
| Keyless | ✓ | ✓ |
| Per-caller quota | ✗ | ✓ |
| Cost attribution | ✗ | ✓ |
| Central policy | ✗ | ✓ |

> "Same models, same client, same API. Start direct for a pilot; put the gateway in front the moment you have more than one team, and the developers never notice — it is one environment variable."

## If something breaks on stage

| Symptom | Fast recovery |
| --- | --- |
| `/status` shows Anthropic API | Env vars set after the app launched. Quit Claude Code, re-dot-source, relaunch. |
| 404 on a model | Wrong deployment name. `cat .deployment-outputs.json` and re-pin. |
| 401 direct | RBAC propagation. Fall back to `-Auth Key`. |
| 401 gateway | Wrong subscription-key header. Switch to `-Auth Entra`. |
| 429 unexpectedly | Previous run consumed the budget. Wait 60s or raise the limit. |
| Gateway slow to first token | Cold start. Always warm it before the demo. |

Full details in [07 — Troubleshooting](07-troubleshooting.md).
