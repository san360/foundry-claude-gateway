# 01 — Architecture

## The two paths

Both paths speak the **Anthropic Messages API**. Nothing about the client payload changes between them — only the base URL and the credential. That is deliberate: it is what makes the gateway a drop-in insertion point rather than a migration.

### Path 1 — Direct

```
Claude Code / SDK
  → https://<account>.services.ai.azure.com/anthropic/v1/messages
  → Foundry evaluates the credential
      • api-key / x-api-key header, or
      • Authorization: Bearer <Entra token for https://ai.azure.com>
        checked against Azure RBAC on the account
  → Claude deployment (GlobalStandard)
```

Lowest latency, fewest moving parts, and per-user RBAC enforced natively by Foundry. What it does *not* give you: cross-user quotas, a single audit surface, prompt/response inspection, multi-backend routing or the ability to change policy without touching clients.

### Path 2 — Via the AI gateway

```
Claude Code / SDK
  → https://<apim>.azure-api.net/anthropic/v1/messages
  → API Management inbound policy
      1. authenticate the caller (subscription key and/or Entra token)
      2. derive a stable caller identity
      3. GET /v1/models only: synthesise the model list from ARM and return it
      4. enforce llm-token-limit (per-caller TPM budget → 429)
      5. emit llm-emit-token-metric to Application Insights
      6. select the Foundry backend
      7. attach a backend credential (managed identity, or pass the caller's token through)
  → Foundry → Claude deployment
  → outbound: stamp x-gateway so the hop is provable
```

The gateway is the control plane. The demo value is that everything in steps 1–7 is configurable at runtime through named values, so you can show three different security postures in a single session without redeploying.

Step 3 is the one capability the gateway *adds* rather than governs. Foundry's Anthropic surface answers `GET /v1/models` with `404 api_not_supported`, so Claude Desktop's **Model discovery** toggle cannot work on the direct path. The gateway answers the call itself — listing the account's Anthropic-format deployments over ARM with its own managed identity — so the client's model picker populates itself. Details in [04-claude-code-gateway.md → Model discovery](04-claude-code-gateway.md#model-discovery).

## Why these specific choices

| Decision | Reason |
| --- | --- |
| API Management **v2 tier** (`BasicV2`+) | The Anthropic Messages API schema for `llm-*` policies is only supported on v2 tiers. Classic Developer/Basic tiers cannot parse Anthropic token usage. |
| API path segment `anthropic` | Claude Code appends `/v1/messages` to whatever base URL it is given. Matching Foundry's own `/anthropic` prefix means the gateway is a byte-for-byte URL substitution. |
| Subscription key header `x-api-key` | The Foundry Anthropic surface expects Anthropic's own `x-api-key` and rejects `api-key` with a `401`. Using the same header at the gateway means `ANTHROPIC_FOUNDRY_API_KEY` works unchanged against both endpoints, and it is one of only two schemes Claude Desktop can send. Configurable via `gatewaySubscriptionKeyHeader`. |
| `buffer-response="false"` | Claude Code streams every request as server-sent events. Buffering breaks streaming and makes the gateway look broken. |
| `timeout="240"` | Long agentic turns with extended thinking routinely exceed the 300s default assumptions of simpler APIs; 240 is the attribute maximum. |
| Backend auth via **managed identity** by default | Lets you set `disableFoundryLocalAuth = true` so the Foundry account has *no* usable keys, and the only credential in the system is a workload identity Azure rotates. It also means a client authenticating with a *gateway* key never holds a Foundry credential. |
| `SecurityControl=Ignore` tag, on by default | Tenant policy forces `disableLocalAuth = true` on every Cognitive Services account unless the resource is exempt, which would make the key-based scenarios undeployable. The tag opts this demo out. It is a demo affordance — drop it (`allowLocalAuthExemption = false`) for anything real, and use Entra. |
| Deployments chained with `dependsOn` | Foundry serializes model deployments under one account; concurrent creates return HTTP 409. |
| Model version `'2'` | "Hosted on Azure" — inference stays inside Azure. Version `'1'` routes to Anthropic-hosted infrastructure. |
| Separate `monitoring` module deployed first | Both APIM and the API diagnostics need the Application Insights resource ID before they can be created. |

## Resolving the circular dependency

The gateway needs Foundry's URL; Foundry needs the gateway's managed-identity principal ID for the role assignment. `main.bicep` breaks the cycle by ordering the modules:

```
monitoring                 (no dependencies)
   ↓
apim                       creates the service + system-assigned identity
   ↓                       outputs principalId
foundry                    creates the account and grants principalId
   ↓                       Cognitive Services User
   ↓                       outputs anthropicBaseUrl + deployment names
gatewayApi                 creates the backend pointing at anthropicBaseUrl,
                           the named values, the API, operations and policy
```

The role assignment therefore exists **before** the API is published, so the first request through the gateway already has permission. Azure RBAC propagation can still take a few minutes; see [troubleshooting](07-troubleshooting.md).

## The policy, step by step

`infra/policies/anthropic-api.xml` is loaded with `loadTextContent` and templatized at deploy time (`__TOKENS_PER_MINUTE__`, `__BACKEND_ID__` are replaced by Bicep `replace()`).

| Stage | Policy | What it demonstrates |
| --- | --- | --- |
| inbound | `choose` on `{{client-auth-mode}}` | Three client auth postures from one deployment |
| inbound | `validate-azure-ad-token` | Entra token validation at the edge, before any spend |
| inbound | `set-variable callerId` | Stable identity from the `oid`/`appid` claim, falling back to the subscription then the client IP |
| inbound | `send-request` + `return-response` on `models-list` | Model discovery the backend cannot serve — authenticated, cached, and filtered to Anthropic-format deployments |
| inbound | `llm-token-limit` | Per-caller tokens-per-minute budget with `Retry-After`, understands the Anthropic schema |
| inbound | `llm-emit-token-metric` | Prompt/completion/total tokens dimensioned by caller into Application Insights |
| inbound | `set-backend-service` | Backend abstraction — the seam where you would add load balancing or failover pools |
| inbound | `choose` on `{{backend-auth-mode}}` | Credential swap vs. passthrough |
| inbound | `authentication-managed-identity` | Zero stored secrets between gateway and model |
| inbound | header hygiene | The gateway credential never reaches the model backend |
| backend | `forward-request buffer-response="false"` | SSE streaming survives the hop |
| outbound | `set-header x-gateway` | Visible proof the request traversed the gateway |
| on-error | `set-header x-gateway-error` | Fast diagnosis during a live demo |

### Named values you can flip at runtime

| Named value | Values | Effect |
| --- | --- | --- |
| `client-auth-mode` | `subscriptionKey`, `entra`, `either` | How callers prove who they are |
| `backend-auth-mode` | `managedIdentity`, `passthrough` | Whether the gateway swaps or forwards the caller credential |
| `entra-tenant-id` | tenant GUID | Which tenant issues acceptable tokens |
| `entra-audience` | e.g. `https://ai.azure.com` | Expected `aud` claim |
| `foundry-token-resource` | e.g. `https://ai.azure.com` | Resource the gateway MI requests |
| `foundry-deployments-uri` | ARM deployments URL | Source of the synthesised `/v1/models` list |

Use `./scripts/Set-GatewayAuthMode.ps1` to change them. Changes take effect on the next request.

Model discovery is a deploy-time switch rather than a named value, because turning it off changes which operations the policy short-circuits: `gatewayModelDiscovery` (default `true`) and `gatewayModelDiscoveryCacheSeconds` (default `300`).

## Observability

- **Application Insights** receives APIM request telemetry (`apim.bicep` logger + `apim-anthropic-api.bicep` API diagnostics) with 100% sampling and the first 8 KB of request/response bodies, which is what makes the "inspect the prompt" moment possible in a demo.
- **`llm-emit-token-metric`** publishes `Prompt Tokens`, `Completion Tokens` and `Total Tokens` in the `foundry-ai-gateway` namespace, dimensioned by `CallerId`, `ApiId` and `OperationId` — this is the chargeback story.
- **Foundry diagnostics** are separately available on the Cognitive Services account for the direct path.

The contrast is the point: on the direct path you can see *that* a model was called; through the gateway you can see *who* called it, *how much* it cost them, and you can stop them.

## Cost shape

| Component | Driver |
| --- | --- |
| Claude deployments | Claude Consumption Units, billed through Azure Marketplace, per token |
| API Management BasicV2 | Fixed hourly rate per scale unit — the dominant idle cost |
| Log Analytics / App Insights | Ingestion volume; body logging at 8 KB adds up under load |

For a short-lived demo, set `deployGateway = false` to skip API Management entirely if you only need the direct path, and delete the resource group afterwards.
