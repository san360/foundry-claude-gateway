# 06 — Demo script

A 25-minute run of show. Everything below has been rehearsed against the deployed template; timings assume the environment is already deployed and warm.

## Before you start

- [ ] Deployment finished; `.deployment-outputs.json` exists at the repo root.
- [ ] `az login` done, correct subscription selected.
- [ ] `./scripts/Test-ClaudeEndpoint.ps1 -Mode Direct -Auth Entra` passes.
- [ ] `./scripts/Test-ClaudeEndpoint.ps1 -Mode Gateway -Auth Entra` passes.
- [ ] `./scripts/Test-Guardrails.ps1` passes — run it once beforehand, it is the longest act.
- [ ] `./scripts/Set-GatewayAuthMode.ps1 -ClientAuth either -BackendAuth managedIdentity`.
- [ ] Application Insights open in a browser tab, Logs blade ready.
- [ ] Foundry portal open on the deployments blade.
- [ ] Two terminals: one for `claude`, one for scripts.
- [ ] Font size up. Clear terminal history so the `/status` output is visible.

Warm the model with one throwaway request; first-token latency on a cold deployment makes the demo feel slow.

Act 5d fires deliberately harmful probe prompts at the models. Know your audience, and say up front that they are canned safety-test strings from `scripts/guardrail-prompts.json` — not improvised.

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

## Act 5b — The other credential: API keys (3 min, optional)

Run this when the audience asks "what if we can't use Entra?" — a common reality when a tenant blocks user consent, or when the caller is a machine that cannot hold a managed identity.

```powershell
# Direct, with the Foundry account key
./scripts/Test-ClaudeEndpoint.ps1 -Mode Direct -Auth Key

# Gateway, with an API Management subscription key
./scripts/Test-ClaudeEndpoint.ps1 -Mode Gateway -Auth Key
```

> "Both return 200, so keys work on both paths. But look at what the client is actually holding. On the direct path it is the Foundry account key — one shared secret, full access, and rotating it breaks every caller at once. Through the gateway it is a subscription key scoped to that one consumer: I can revoke it on its own, meter it on its own, and it grants nothing on Foundry, because the gateway still calls the model with its own managed identity."

Show the setting that made this possible at all:

```powershell
az cognitiveservices account show -n <account> -g <rg> `
  --query "{localAuth:properties.disableLocalAuth, tags:tags}"
```

> "Tenant policy turns API keys off on every Cognitive Services account. This one is tagged `SecurityControl=Ignore`, which is the exemption — that is the only reason the key demo runs. In your own tenant, that tag is a conversation with your security team, and the honest answer is that Entra is the better default anyway."

Then bring it back to Claude Desktop:

> "This also matters for the desktop app. Claude Code signs in as a Microsoft first-party client, so `az login` is enough. Claude Desktop needs its own app registration, and if your tenant blocks user consent, that sign-in stops dead at 'Need admin approval'. The key path is what unblocks a demo on the day; the admin grant is what you want for the rollout."

## Act 5c — Something the gateway can do that Foundry can't (2 min)

Everything so far has been the gateway *governing* traffic. This is the gateway *adding* a capability, and it lands well because it is two commands and an obvious difference.

```powershell
./scripts/Test-ClaudeEndpoint.ps1 -Mode Direct  -Auth Entra -ListModels   # 404
./scripts/Test-ClaudeEndpoint.ps1 -Mode Gateway -Auth Key   -ListModels   # 200, lists the deployments
```

> "Same request, `GET /v1/models`. Foundry's Anthropic surface doesn't implement it, so it 404s — which is why Claude Desktop's *Model discovery* toggle is off on the direct path and you type your model names in by hand. Through the gateway it returns the list, because the gateway answers the call itself: it reads the account's deployments with its own managed identity and shapes them into Anthropic's format. Turn the toggle on and the model picker populates itself. Add a deployment in Foundry, and it shows up in the client without anyone touching a config file."

If someone asks whether other Foundry models could be listed here:

> "Deliberately not. This gateway speaks the Anthropic Messages API. Your GPT and Llama deployments live on a different Foundry surface with a different schema, so listing one here would put it in the picker and then fail on every request. The policy filters on `format == Anthropic` for that reason. Making them genuinely work is a translation layer — and streaming is where that gets hard."

## Act 5d — Guardrails, and why the direct path has none (4 min)

The strongest beat in the deck, because it is a genuine finding rather than a feature tour, and the audience can watch it happen.

Set it up before running anything:

> "Foundry lets you attach a Responsible AI content filter policy to a deployment. We attached one — every harm category, blocking, at the lowest possible threshold. Azure accepts it. Let's see what it does."

```powershell
./scripts/Test-Guardrails.ps1 -PromptId harm-violence -Mode Direct -ShowResponse
```

`REACHED-MODEL`. Claude declines politely, but the request was never filtered — and pause on the status code:

> "Two hundred. Not four hundred. If Azure's filter had blocked this you'd get a 400 with `content_filter` in it, and that would show up in your logs, your alerts and your compliance report. This is a 200 with `stop_reason: end_turn` — byte for byte the same shape as a successful answer. Claude declined, on its own, and your monitoring has no idea anything happened."

Then the one that lands hardest:

```powershell
./scripts/Test-Guardrails.ps1 -PromptId jailbreak-dan -Mode Direct -ShowResponse
```

> "That one it just answered. Model alignment is good, but it is not a control you own, not a control you configured, and not a control you can evidence to an auditor."

Now the same two prompts through the gateway:

```powershell
./scripts/Test-Guardrails.ps1 -PromptId jailbreak-dan  -Mode Gateway -ShowResponse
./scripts/Test-Guardrails.ps1 -PromptId harm-violence -Mode Gateway -ShowResponse
```

> "403, before the model was ever called — so it cost zero tokens. And the header tells you exactly why: `x-guardrail-blocked: prompt_shield` for the jailbreak, `violence:5` for the other. That's Azure AI Content Safety, running in the API Management policy. Two checks: Prompt Shields for jailbreaks, and severity scoring across four harm categories. You need both — the jailbreak scores zero on every harm category, and the harmful prompt isn't flagged as an attack."

Finish with the whole corpus, which is the slide-worthy moment:

```powershell
./scripts/Test-Guardrails.ps1
```

| | Direct | Gateway |
| --- | --- | --- |
| Harmful prompts stopped before the model | **0 of 6** | **6 of 6** |
| Benign prompts allowed | 3 of 3 | 3 of 3 |

> "Nothing benign was blocked — including 'explain SQL injection and how to prevent it', which a badly tuned filter would kill and make the tool useless for security work. Ninety-three milliseconds of overhead. No extra resource and no extra role assignment: Content Safety runs on the same Foundry account, and the gateway's managed identity already had the permission."

Two questions you should expect:

- **"Will Microsoft fix this?"** — Possibly; treat it as point-in-time. The Bicep already declares the strict policy, so if enforcement is enabled you inherit it, and `Test-Guardrails.ps1` will start reporting `BLOCKED-PLATFORM` instead of `REACHED-MODEL`. Re-run it after Foundry updates.
- **"What about the model's responses?"** — Inbound only, deliberately. Claude Code streams every request, and inspecting responses means buffering them, which breaks streaming for the primary client. Honest limitation, documented in [08 — Guardrails](08-guardrails.md).

## Act 6 — Close (1 min)

| | Direct | Gateway |
| --- | --- | --- |
| Setup | 2 environment variables | 2 environment variables |
| Latency | lowest | one extra hop (~93 ms with guardrails) |
| Entra auth | ✓ | ✓ (two topologies) |
| Keyless | ✓ | ✓ |
| Key auth, if you need it | shared account key | per-consumer, revocable |
| Per-caller quota | ✗ | ✓ |
| Cost attribution | ✗ | ✓ |
| Central policy | ✗ | ✓ |
| Model discovery (`GET /v1/models`) | ✗ — Foundry returns 404 | ✓ — synthesised by the gateway |
| Enforceable content guardrails | ✗ — the Azure filter does not run for Claude | ✓ — Content Safety, 6 of 6 blocked |

> "Same models, same client, same API. Start direct for a pilot; put the gateway in front the moment you have more than one team, and the developers never notice — it is one environment variable."

## If something breaks on stage

| Symptom | Fast recovery |
| --- | --- |
| `/status` shows Anthropic API | Env vars set after the app launched. Quit Claude Code, re-dot-source, relaunch. |
| 404 on a model | Wrong deployment name. `cat .deployment-outputs.json` and re-pin. |
| 401 direct | RBAC propagation. Fall back to `-Auth Key`. |
| 401 gateway | Wrong subscription-key header. Switch to `-Auth Entra`. |
| 429 unexpectedly | Previous run consumed the budget. Wait 60s or raise the limit. |
| Guardrail blocks something benign | Expected on a tuned-tight threshold — say so, then run `-PromptId control-security-topic` to show it does not block security topics. |
| Guardrail blocks nothing on the gateway | Check `gatewayGuardrailsEnabled` in `.deployment-outputs.json`; the policy fails open if Content Safety is unreachable. |
| Gateway slow to first token | Cold start. Always warm it before the demo. |

Full details in [07 — Troubleshooting](07-troubleshooting.md).
