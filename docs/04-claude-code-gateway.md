# 04 — Claude Code via the Azure API Management AI gateway

Same client, same API, one changed environment variable.

```
Claude Code → https://<apim>.azure-api.net/anthropic/v1/messages
            → API Management (governance, identity, telemetry)
            → https://<foundry>.services.ai.azure.com/anthropic/v1/messages
```

## Why an AI gateway

| Capability | Direct | Via gateway |
| --- | --- | --- |
| Per-caller tokens-per-minute quota | ✗ | ✓ `llm-token-limit` |
| Token metrics dimensioned by caller | ✗ | ✓ `llm-emit-token-metric` |
| Central Entra validation before spend | partial | ✓ `validate-azure-ad-token` |
| Clients hold zero Foundry credentials | ✗ | ✓ managed-identity swap |
| Change auth posture without touching clients | ✗ | ✓ named values |
| Prompt/response inspection | ✗ | ✓ App Insights body logging |
| **Enforceable content guardrails** | ✗ — the Azure RAI filter does not run for Claude | ✓ Azure AI Content Safety, inbound |
| Model discovery (`GET /v1/models`) | ✗ `404 api_not_supported` | ✓ synthesised from ARM |
| Multi-backend routing, failover, retries | ✗ | ✓ backends and pools |
| One endpoint for many models/providers | ✗ | ✓ |

The Anthropic Messages API schema is understood natively by the `llm-*` policies **on API Management v2 tiers**, which is why this template only allows `BasicV2`, `StandardV2` and `PremiumV2`.

## Configure Claude Code

The key difference: use `ANTHROPIC_FOUNDRY_BASE_URL` (not `ANTHROPIC_FOUNDRY_RESOURCE`), and **include the `/anthropic` path**. Claude Code only auto-appends `/anthropic` for the resource form.

### PowerShell

```powershell
$env:CLAUDE_CODE_USE_FOUNDRY = '1'
Remove-Item Env:ANTHROPIC_FOUNDRY_RESOURCE -ErrorAction SilentlyContinue
$env:ANTHROPIC_FOUNDRY_BASE_URL = 'https://apim-claudedemo-demo-abc123.azure-api.net/anthropic'

$env:ANTHROPIC_DEFAULT_SONNET_MODEL = 'claude-sonnet-4-6'
$env:ANTHROPIC_DEFAULT_HAIKU_MODEL  = 'claude-haiku-4-5'

# Credential: either an APIM subscription key...
$env:ANTHROPIC_FOUNDRY_API_KEY = '<apim-subscription-key>'
# ...or nothing at all, and let the Entra credential chain handle it.

claude
```

### Or use the helper

```powershell
. ./scripts/Set-ClaudeCodeEnv.ps1 -Mode Gateway -Auth Key      # subscription key
. ./scripts/Set-ClaudeCodeEnv.ps1 -Mode Gateway -Auth Entra    # keyless
```

```bash
source ./scripts/set-claude-code-env.sh gateway entra
```

`/status` still reports **Microsoft Foundry** as the API provider — the gateway is transparent to the client. To prove the hop, look for the `x-gateway` response header (`scripts/Test-ClaudeEndpoint.ps1` prints it).

## Client credentials at the gateway

`{{client-auth-mode}}` controls what the gateway accepts:

| Mode | Accepts | Notes |
| --- | --- | --- |
| `subscriptionKey` | API Management subscription key only | Simplest. Good for machine clients and for showing quota per key. |
| `entra` | Microsoft Entra ID bearer token only | Keyless. The gateway validates issuer, audience and signature before any spend. |
| `either` | Entra token if present, otherwise the subscription key | **Default.** Lets you demo both without touching config. |

Switch live:

```powershell
./scripts/Set-GatewayAuthMode.ps1 -ClientAuth entra
./scripts/Set-GatewayAuthMode.ps1 -Show
```

### The subscription key header

The API is configured with `subscriptionKeyParameterNames.header = 'api-key'` (parameter `gatewaySubscriptionKeyHeader`) so Claude Code's `ANTHROPIC_FOUNDRY_API_KEY` lands on a header the gateway recognises — meaning **client code is byte-for-byte identical between the two paths**.

> **Verify this in your environment.** Anthropic clients historically send `x-api-key`; the Foundry surface accepts both `api-key` and `x-api-key`. If gateway calls return `401 Access denied due to missing subscription key`, Claude Code sent the other header name. Redeploy with `gatewaySubscriptionKeyHeader = 'x-api-key'`.
>
> You cannot fix this in policy: API Management validates the subscription key **before** the inbound policy runs, so a `set-header` rename comes too late. Alternatively set `gatewayClientAuthMode = 'entra'` and sidestep subscription keys entirely.

Retrieve the key:

```powershell
$subId = az account show --query id -o tsv
az rest --method post --uri "/subscriptions/$subId/resourceGroups/<rg>/providers/Microsoft.ApiManagement/service/<apim>/subscriptions/claude-code-demo/listSecrets?api-version=2024-05-01" --query primaryKey -o tsv
```

## Backend credentials

`{{backend-auth-mode}}` controls how the gateway authenticates *to Foundry*:

### `managedIdentity` (default)

```
client (key or Entra token) → gateway → [MI token for https://ai.azure.com] → Foundry
```

The gateway strips whatever credential the client sent and attaches its own system-assigned managed identity token. Consequences:

- Clients never hold a Foundry credential.
- Only one identity — the gateway — needs `Cognitive Services User` on the Foundry account.
- You can set `disableFoundryLocalAuth = true` so Foundry has **no working keys at all**.
- Trade-off: Foundry sees every request as the gateway. Per-user attribution now lives in API Management telemetry, not in Foundry's logs.

### `passthrough`

```
client (Entra token) → gateway validates → forwards the same token → Foundry evaluates RBAC per user
```

- Foundry enforces per-user RBAC natively; each developer needs their own role assignment.
- Native end-to-end audit: the Foundry resource log shows the real caller.
- Requires clients to present an Entra token — subscription-key-only callers will get `401` from Foundry.
- The gateway is still doing quota, metrics and routing.

Switch live:

```powershell
./scripts/Set-GatewayAuthMode.ps1 -BackendAuth passthrough
```

This is the most useful thing to show a security architect: the same deployment supports both "gateway as trust boundary" and "gateway as transparent policy layer".

## Governance features to demonstrate

### Per-caller token budget

`llm-token-limit` is keyed on `callerId` — the Entra `oid` claim, else the API Management subscription ID, else the client IP. Once the budget is spent the gateway returns `429` with `Retry-After`, and every successful response carries:

```
x-gateway-tokens-remaining: 18342
x-gateway-tokens-consumed: 1658
```

Lower `gatewayTokensPerMinute` to something small (say 2000) and redeploy if you want to trigger a 429 on stage. `estimate-prompt-tokens="false"` means the gateway counts actual usage reported by the model rather than estimating up front — accurate, but the limit is enforced from the *previous* request's accounting.

### Token metrics

`llm-emit-token-metric` publishes `Prompt Tokens`, `Completion Tokens` and `Total Tokens` to the `foundry-ai-gateway` namespace. Two caveats that cost time if you meet them cold:

- These are **Azure Monitor custom metrics**, not Log Analytics rows. A `customMetrics` KQL query returns nothing even when the policy is working correctly. Read them through the metrics API — the exact call is in [07 — Troubleshooting → Token spend](07-troubleshooting.md#token-spend).
- Emission is opt-in per diagnostic entity via **`metrics: true`**, which the portal does not surface. `apim-anthropic-api.bicep` sets it. Without it the policy runs silently and emits nothing.

The `CallerId` dimension — the actual chargeback story — additionally needs *Custom metrics (Preview) → With dimensions* enabled on the Application Insights component, which is portal-only. See [Token metrics are empty](07-troubleshooting.md#token-metrics-are-empty).

For a demo, the response headers below are a faster and more reliable way to show the same thing.

### Semantic cache partitioning

Cached answers are partitioned by caller, so one caller can never be served another caller's completion. A second, optional partition key is the `x-gateway-cache-scope` request header:

```http
x-gateway-cache-scope: project-alpha
```

Send it to isolate a project, session or tenant inside a single caller. Send a fresh GUID to guarantee a cold partition — that is the only reliable way to force a model call, because a random nonce *inside the prompt* does not work: the lookup is semantic, so the embedding ignores it and the request still hits.

Worth knowing before you measure anything: **a cache hit reports `x-gateway-tokens-consumed: 0`**, because the backend is never called. That is the feature working, not a broken counter.

### Request tracing

API diagnostics are configured with 100% sampling and 8 KB of request/response body capture, so you can show the actual Claude Code system prompt and tool definitions flowing through:

```kusto
requests
| where name contains "messages"
| project timestamp, resultCode, duration, customDimensions
| order by timestamp desc
```

Turn body logging down before anything resembling production — prompts routinely contain source code. Set `gatewayBodyLogBytes = 0` and redeploy.

### Streaming

`<forward-request buffer-response="false" timeout="240" />` is what keeps server-sent events flowing. Claude Code streams every request, so without it the client appears to hang and then dump the whole response at once. Sample 5 in `samples/rest/anthropic.http` demonstrates a streaming call through the gateway.

### Content guardrails

The most important governance feature here, because it covers a gap you cannot close any other way: **Azure's RAI content filter does not run for Claude in Foundry**. You can attach a `raiPolicyName` to the deployment, ARM will confirm it, and nothing will enforce it. On the direct path the only safety layer is Claude's own alignment, which returns refusals as `HTTP 200` — invisible to metrics and alerts.

The gateway closes that gap with the **native `llm-content-safety` policy**, inbound, before the backend is selected. One declarative policy element runs both Content Safety checks:

| Check | Catches |
| --- | --- |
| `shield-prompt` | jailbreaks and prompt-injection attempts |
| `categories` | Hate, Sexual, Violence, SelfHarm scored 0–7 |

Both are needed. Jailbreak prompts score **0** on every harm category, and harm prompts are **not** flagged as attacks — either check alone misses half of the probe corpus.

Content Safety is served by the **same AIServices account** on the same hostname as the Claude deployments, and `Cognitive Services User` — which the gateway identity already holds — covers its data plane. No extra resource, no extra role assignment.

The policy is preceded by a short **normalisation step** that flattens the request into a canonical, bounded probe body. That step is not cosmetic: applied to a raw Anthropic body, the native policy **skips inspection entirely when `system` is an array of content blocks** — the shape Claude Desktop and Claude Code send — and **returns 403 on any body over 10,000 characters**, which is most real Claude Code traffic. Both behaviours are reproduced and explained in [08 — Guardrails](08-guardrails.md#how-we-use-apims-built-in-llm-content-safety-policy).

A blocked request never reaches the model, so it costs zero model tokens:

```http
HTTP/1.1 403 Forbidden

{ "statusCode": 403, "message": "Request failed content safety check." }
```

The native policy does not name the category that fired; that detail is in the APIM diagnostic logs.

An allowed request carries proof the check ran rather than being skipped:

```http
x-guardrail: checked:allow
x-guardrail-enforced-by: apim-llm-content-safety
```

Measured cost is about **93 ms** per request. Demonstrate it with:

```powershell
./scripts/Test-Guardrails.ps1 -PromptId jailbreak-dan -Mode Both -ShowResponse
```

Direct answers it. The gateway returns `403`. Full detail, tuning and the reproducible negative result for the platform filter: [08 — Guardrails](08-guardrails.md).

## Operations exposed

| Method | Path | Purpose |
| --- | --- | --- |
| POST | `/v1/messages` | Inference — the one that matters |
| POST | `/v1/messages/count_tokens` | Token counting with no inference charge |
| GET | `/v1/models` | Model discovery — **answered by the gateway itself**, see below |
| POST | `/*` | Catch-all so future Anthropic endpoints keep working |
| GET | `/*` | Catch-all |

The catch-alls matter: Claude Code calls endpoints beyond `/v1/messages`, and a gateway that only publishes the one operation will fail in confusing ways.

## Model discovery

This is the clearest capability the gateway adds that the direct path simply cannot offer, so it is worth a slide of its own in the demo.

Claude Desktop has a **Model discovery** toggle. When it is on, the app calls `GET {base}/v1/models` at launch and populates its model picker from the response. When it is off, you type the model names in by hand and keep them in step with the deployments yourself.

Foundry's Anthropic surface does not implement that endpoint:

```console
$ curl https://<foundry>.services.ai.azure.com/anthropic/v1/models -H "x-api-key: ..."
404 {"error":{"code":"api_not_supported","message":"..."}}
```

So **the toggle can never work against Foundry directly** — leave it off there. Through the gateway it works, because the gateway answers the call itself instead of forwarding it.

### How the gateway answers it

The inbound policy intercepts `context.Operation.Id == "models-list"`, asks ARM for the Foundry account's deployments using the gateway's own managed identity, and reshapes the result into Anthropic's `/v1/models` envelope:

```json
{
  "data": [
    { "type": "model", "id": "claude-haiku-4-5",  "display_name": "claude-haiku-4-5",  "created_at": "..." },
    { "type": "model", "id": "claude-sonnet-4-6", "display_name": "claude-sonnet-4-6", "created_at": "..." }
  ],
  "has_more": false,
  "first_id": "claude-haiku-4-5",
  "last_id": "claude-sonnet-4-6"
}
```

Responses carry `x-gateway-synthesised: models-list` so you can tell at a glance that the gateway produced the answer rather than the backend. Note there is **no** `x-gateway` header on these responses: `return-response` short-circuits the pipeline before the outbound section runs.

The smoke-test script demonstrates the contrast in two commands:

```powershell
./scripts/Test-ClaudeEndpoint.ps1 -Mode Gateway -Auth Key -ListModels   # 200, lists the deployments
./scripts/Test-ClaudeEndpoint.ps1 -Mode Direct  -Auth Entra -ListModels # 404 api_not_supported
```

Four design points are worth calling out, because each one is a decision rather than an accident:

- **`id` is the *deployment* name, not the model id.** Foundry's Messages API routes on the deployment name, so the value the client discovers is exactly the value it must send back in `"model"`. Returning `claude-sonnet-4-6-20260514` would look tidier and break every request.
- **The block sits after authentication but before token governance.** Your deployment inventory is not public — an anonymous call gets 401. But a metadata call consumes no model tokens, and `llm-token-limit` has no request body to inspect on a `GET`, so discovery is deliberately routed around it.
- **The result is cached** (`modelDiscoveryCacheSeconds`, default 300). Discovery fires at client launch, so a short cache keeps ARM off the hot path without hiding a newly added deployment for long.
- **ARM failures degrade to an empty list, not an error.** `ignore-error="true"` on the `send-request` plus a `try/catch` mean a transient ARM problem leaves the client with whatever model list it already had, rather than blocking launch.

No extra RBAC is needed: the gateway's managed identity already holds **Cognitive Services User** for the Foundry account, and that role carries `Microsoft.CognitiveServices/*/read`, which covers reading deployments.

### Only Anthropic-format deployments are listed

The policy filters on `properties.model.format == "Anthropic"` and `provisioningState == "Succeeded"`. A Foundry account can host GPT, Llama or Mistral deployments alongside Claude, and it is tempting to expose all of them here.

Don't. This API speaks the **Anthropic Messages API**, and Foundry serves non-Anthropic models on completely different surfaces (`/openai/v1/chat/completions`, `/models/chat/completions`) with a different request and response schema. A GPT deployment advertised through discovery would appear in Claude Desktop's picker and then fail on **every** request. Listing only what actually works is the honest behaviour.

Making non-Claude models genuinely usable from an Anthropic client is possible but is a different project: it needs bidirectional Anthropic ↔ OpenAI translation in the policy, and translating **SSE streaming** between the two event schemas is the hard part. It is out of scope here.

### Turning it off

```bicep
gatewayModelDiscovery: false
```

The operation then forwards to Foundry like any other and returns Foundry's own 404 — useful if you want to demonstrate the unmodified behaviour.

## Claude Desktop against the gateway

Claude Desktop treats the gateway as a **separate provider**, not as the Foundry provider with a different URL. The key set is different, and mixing the two produces a config the app silently ignores.

```powershell
./scripts/New-ClaudeConfig.ps1 -Mode Gateway -ClientId <app-client-id> -Apply
```

| Setting | Value |
|---|---|
| `inferenceProvider` | `gateway` |
| `inferenceGatewayBaseUrl` | `https://apim-….azure-api.net/anthropic` — full URL, `/anthropic` included |
| `inferenceGatewayOidc` | JSON: `{issuer, clientId, tokenType, scopes}` |
| `inferenceGatewayOidcAuthFlow` | `browser` or `broker` — **no** `device-code` on this provider |
| `inferenceGatewayApiKey` | static-key alternative, used only when `inferenceCredentialKind=static` |
| `inferenceGatewayAuthScheme` | `bearer` or `x-api-key` — those two values only |

The OIDC block the generator writes:

```json
{
  "issuer": "https://login.microsoftonline.com/<tenant-id>/v2.0",
  "clientId": "<app-client-id>",
  "tokenType": "access_token",
  "scopes": ["https://cognitiveservices.azure.com/.default"]
}
```

### Why the scope is `cognitiveservices.azure.com` and not `ai.azure.com`

This is the one non-obvious constraint in the whole gateway path.

Claude Code's *direct* path uses tokens whose audience is `https://ai.azure.com`. That works because Claude Code authenticates as a Microsoft first-party client. `https://ai.azure.com` has **no enumerable service principal in the tenant**, so you cannot add it as a required resource on your own app registration — a custom app can never request that audience, and Claude Desktop's gateway sign-in uses a custom app registration.

`https://cognitiveservices.azure.com` *does* have a service principal and is user-consentable, so a custom app can obtain it. The gateway therefore accepts **both** audiences:

```bicep
gatewayEntraAudienceAdditional: 'https://cognitiveservices.azure.com'
```

which lands in the policy as a second `<audience>` inside `validate-azure-ad-token`, and is surfaced as the `gatewayEntraAudiences` deployment output. One gateway serves the CLI and the desktop app without either client having to change.

Accepting a second audience is safe **only under `backendAuthMode = 'managedIdentity'`**, the default. In that mode the policy discards the caller's `Authorization` header and replaces it with the gateway's own managed-identity token before calling Foundry, so the inbound audience is purely an authentication gate — it never reaches the backend.

> Under `backendAuthMode = 'passthrough'` the caller's token is forwarded to Foundry unchanged, so it *must* carry `aud: https://ai.azure.com`. **Passthrough is therefore incompatible with Claude Desktop's gateway sign-in.** Use `managedIdentity`, or point the desktop app at Foundry directly.

Also remember `subscriptionRequired` must be off whenever Entra is a permitted client credential — APIM rejects the request on the missing key before your policy ever runs.

### The better option: a dedicated sign-in app

Everything above works, but it inherits the consent problem, because `https://cognitiveservices.azure.com` is still an API **Microsoft** owns. You cannot pre-authorize someone else's API, so a tenant with restricted user consent stops every user at *"Need admin approval"*.

Registering an application whose only job is to be an audience removes that constraint entirely:

```powershell
./scripts/New-GatewaySsoAppRegistration.ps1 -AllowedGroup 'Claude Gateway Users'
./scripts/deploy.ps1 -GatewaySsoAppId <app-id> -AllowedGroupId <group-object-id>
./scripts/New-ClaudeConfig.ps1 -Mode Gateway -GatewaySsoClientId <app-id> -Apply
```

The OIDC block then points at your own scope:

```json
{
  "issuer": "https://login.microsoftonline.com/<tenant-id>/v2.0",
  "clientId": "<gateway-sso-app-id>",
  "tokenType": "access_token",
  "scopes": ["openid", "profile", "email", "api://<gateway-sso-app-id>/Gateway.Access"]
}
```

Because the client is pre-authorized for that scope, **no consent prompt is raised at all** — not for the user, not for an admin. The user also needs no Foundry role, because the gateway still calls Foundry with its own managed identity. Who is allowed in is decided separately from the `groups` claim, at the gateway.

Full walkthrough, including the group-claim design and why "Assignment required" is deliberately left off: [05 — Scenario C](05-entra-authentication.md#scenario-c--gateway-interactive-sign-in-from-claude-desktop).

### Key-based access at the gateway

The gateway's key scenario uses an **API Management subscription key**, not the Foundry key. The gateway keeps its own managed-identity credential to Foundry, so the caller never holds a Foundry secret — which is one of the better arguments for putting a gateway in front of the model in the first place.

```powershell
./scripts/New-ClaudeConfig.ps1 -Mode Gateway -CredentialKind static -EnvFile .env.gateway
./scripts/Set-ClaudeDesktopConfig.ps1 -EnvFile .env.gateway
```

That writes:

```
inferenceCredentialKind=static
inferenceGatewayApiKey=<APIM subscription key>
inferenceGatewayAuthScheme=x-api-key
```

**The header has to match.** Claude Desktop can send a gateway credential in exactly two ways — `Authorization: Bearer` or `x-api-key` — so API Management must be told to look for its subscription key on `x-api-key`. That is a deployment parameter, not a client one:

```bicep
param gatewaySubscriptionKeyHeader = 'x-api-key'   // the default in this repo
```

It also happens to be the header the Foundry Anthropic endpoint itself expects, so one header name works across both scenarios. If you change it to something else, Claude Desktop's key path stops working and `New-ClaudeConfig.ps1` will warn you.

Compared with the Foundry key on the direct path, the gateway key is the better key story: it is per-consumer, revocable on its own, rate-limited by the product's token budget, and it never grants access to Foundry itself.

| | Direct + Foundry key | Gateway + APIM key |
|---|---|---|
| Secret held by the client | Foundry account key | APIM subscription key |
| Blast radius if leaked | full account, all callers | that one subscription |
| Revoke without affecting others | no — key rotation hits everyone | yes — delete the subscription |
| Token budget / quota | none | `llm-token-limit` per subscription |
| Usage attribution | none | per subscription, in Application Insights |

## Same thing from the SDK

```python
from anthropic import AnthropicFoundry
from azure.identity import DefaultAzureCredential, get_bearer_token_provider

client = AnthropicFoundry(
    base_url="https://apim-claudedemo-demo-abc123.azure-api.net/anthropic",
    azure_ad_token_provider=get_bearer_token_provider(
        DefaultAzureCredential(), "https://ai.azure.com/.default"
    ),
)
```

Only `base_url` differs from the direct sample. Runnable: `samples/python/hello_claude.py --path gateway --auth entra`.

## Iterating on the policy

Edit `infra/policies/anthropic-api.xml`, then redeploy — the policy is embedded via `loadTextContent`, so only the API module changes and the update takes about a minute.

```powershell
[xml](Get-Content infra/policies/anthropic-api.xml -Raw)   # parse first, always
./scripts/deploy.ps1 -Location eastus2
```

Watch for the two XML traps: no `--` inside comments, and escape `"` as `&quot;` inside attributes (element content is fine unescaped).

## Verified against a live deployment

Executed 2026-08-20 against API Management `BasicV2` in `eastus2`, fronting a Foundry
account with `claude-haiku-4-5` and `gatewayBackendAuthMode = 'managedIdentity'`.
The Foundry account had local (key) authentication disabled by tenant policy, so every
result below was achieved with **no Foundry credential in existence anywhere**.

### Client authentication matrix � `gatewayClientAuthMode = 'either'`

| Caller presents | Result | Notes |
|---|---|---|
| API Management subscription key | `200` | `context.Subscription` resolves and the policy accepts |
| Microsoft Entra ID bearer token | `200` | `validate-azure-ad-token` checks `aud` and `tid` |
| Neither | `401` | Rejected by the policy with an Anthropic-shaped error body |

Successful responses carry the gateway markers:

```
x-gateway: azure-api-management
x-gateway-tokens-remaining: 19951
x-gateway-tokens-consumed: 49
```

### `subscriptionRequired` must be off whenever Entra is permitted

This is the one non-obvious part of the template, and it was found by testing rather than
by reading documentation.

**API Management validates the subscription key in its own pipeline, before the inbound
policy runs.** If the API is deployed with `subscriptionRequired = true`, an Entra-only
caller never reaches `validate-azure-ad-token`; the gateway rejects it first with:

```
HTTP 401  x-gateway-error: SubscriptionKeyNotFound
{ "statusCode": 401, "message": "Access denied due to missing subscription key. ..." }
```

So the template sets:

```bicep
subscriptionRequired: gatewayClientAuthMode == 'subscriptionKey'
```

Turning the built-in check off moves responsibility to the policy, which must then reject
anonymous callers itself � otherwise the API would be open. The `either` branch does that
by testing `context.Subscription == null`. Usefully, **API Management still resolves a
valid subscription key into `context.Subscription` even when `subscriptionRequired` is
`false`**, which is what makes a single `either` mode possible at all.

### Backend authentication � both topologies confirmed

| `gatewayBackendAuthMode` | Caller auth | Result |
|---|---|---|
| `managedIdentity` | subscription key | `200` |
| `managedIdentity` | Entra token | `200` |
| `passthrough` | Entra token | `200` � caller's own token reaches Foundry, RBAC evaluated per user |
| `passthrough` | subscription key | `401` at Foundry � nothing to forward |

The last row is expected, not a defect: `passthrough` deliberately has no gateway-owned
credential. Switch modes without redeploying:

```powershell
./scripts/Set-GatewayAuthMode.ps1 -BackendAuth passthrough
./scripts/Set-GatewayAuthMode.ps1 -BackendAuth managedIdentity
```

### Token governance � confirmed enforcing

With `gatewayTokensPerMinute = 300`, the `llm-token-limit` policy throttled on the third
request:

```
req 1 -> HTTP 200   x-gateway-tokens-remaining: 38
req 2 -> HTTP 200   x-gateway-tokens-remaining: 0
req 3 -> HTTP 429   Retry-After: 41
{ "statusCode": 429, "message": "Token limit is exceeded. Try again in 41 seconds." }
```

Note there are **two independent throttles**, and the tighter one wins. With a generous
gateway budget but a small `haikuCapacity`, Foundry's own per-deployment quota answers
first and the error text differs:

```
{"error":{"code":"RateLimitReached",
  "message":"Rate limit of 2000 per 60s exceeded for UserByModelByMinuteOutputTokens."}}
```

Read the error body to know which layer throttled: `x-gateway-error:
OpenAITokenLimitExceeded` and a `Retry-After` header mean the gateway, while a
`RateLimitReached` / `UserByModelByMinute...` body means the model deployment. Raise
`haikuCapacity` if you intend to demonstrate gateway-side governance.

### Model discovery — confirmed gateway-only

`GET /v1/models`, against the live deployment:

| Path | Credential | Result |
| --- | --- | --- |
| Gateway | subscription key | **200** — both deployments, `x-gateway-synthesised: models-list` |
| Gateway | Entra bearer token | **200** — same payload |
| Gateway | none | **401** — the inventory is not public |
| Foundry direct | account key | **404** `api_not_supported` |

The direct 404 is the point: it is the same request, and only the gateway can answer it. `POST /v1/messages` was re-tested alongside and still returns 200, confirming the discovery branch does not interfere with the inference path.

### Guardrails — confirmed enforcing, and confirmed absent on the direct path

The nine-prompt corpus in `scripts/guardrail-prompts.json`, run against the live deployment at severity threshold 4:

| Prompt group | Direct to Foundry | Via the gateway |
| --- | --- | --- |
| 3 benign controls | **200** answered | **200** answered — no false positives |
| 2 jailbreaks | **200** — one *answered outright*, one refused by the model | **403** on both |
| 4 harm categories | **200** on all four, model refusals only | **403** on all four |

**Direct stopped 0 of 6. The gateway stopped 6 of 6 and allowed 3 of 3 benign prompts.**

Separately confirmed, and the reason this section exists: a custom RAI policy named `claude-strict` — every harm category set to `blocking` at `severityThreshold: Low` on both prompt and completion, plus Jailbreak and Protected Material Text — was deployed and attached to `claude-haiku-4-5`. ARM reports `raiPolicyName: claude-strict`. A prompt that policy forbids still returned **200**. The platform filter is configured, reported, and inert.

Latency, measured over 8 samples at `max_tokens=16` (medians): direct **757 ms**, gateway with one Content Safety probe **759 ms**, gateway with two probes (a system prompt is present) **593 ms**, and a blocked request **454 ms** because the model is never called. The guardrail cost is **within run-to-run noise** — the two-probe row is faster only because that particular system prompt asks for a one-sentence answer, so it is not a like-for-like comparison. Allowed responses carried `x-guardrail: checked:allow`.

Confirmed on **app-shaped payloads** as well, not just curl bodies: a request with `system` as an array of blocks, two tool definitions and a three-turn history is blocked identically, and `stream: true` and `stream: false` give the same result on all nine corpus prompts. That matters because Claude Desktop and Claude Code always stream — so the guardrail demo works entirely inside the app. See [09 — Test prompts](09-test-prompts.md#a3--the-guardrail-demo-entirely-in-the-chat-window) for the in-chat sequence.

### Native AI policies — 16 of 16 verified

`./scripts/Test-NativePolicies.ps1` exercises all three stock `llm-*` policy families against the live deployment:

| Section | Result |
| --- | --- |
| `llm-content-safety` | **8 of 8** — including `system`-as-array, the severity-dilution bypass, a 14,475-character benign paste, and harmful text with tool definitions present |
| `llm-emit-token-metric` / `llm-token-limit` | **4 of 4** — `x-gateway-tokens-consumed` and `-remaining` track real usage against the 20,000/min ceiling |
| `llm-semantic-cache-lookup` / `-store` | **4 of 4** — identical *and reworded* prompts replay the byte-identical stored completion in ~0.6 s; an unrelated prompt misses |

Token metrics were separately confirmed in the Azure Monitor metrics store after enabling `metrics: true` on the API diagnostic — `Prompt Tokens`, `Completion Tokens` and `Total Tokens` all report non-zero totals under the `foundry-ai-gateway` namespace.
