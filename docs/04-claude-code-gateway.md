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

`llm-emit-token-metric` publishes to the `foundry-ai-gateway` namespace with `CallerId`, `ApiId` and `OperationId` dimensions. In Application Insights:

```kusto
customMetrics
| where name in ("Prompt Tokens", "Completion Tokens", "Total Tokens")
| extend caller = tostring(customDimensions["CallerId"])
| summarize tokens = sum(value) by name, caller, bin(timestamp, 5m)
| render timechart
```

That query is the chargeback story in one screen.

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

## Operations exposed

| Method | Path | Purpose |
| --- | --- | --- |
| POST | `/v1/messages` | Inference — the one that matters |
| POST | `/v1/messages/count_tokens` | Token counting with no inference charge |
| GET | `/v1/models` | Model discovery |
| POST | `/*` | Catch-all so future Anthropic endpoints keep working |
| GET | `/*` | Catch-all |

The catch-alls matter: Claude Code calls endpoints beyond `/v1/messages`, and a gateway that only publishes the one operation will fail in confusing ways.

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
