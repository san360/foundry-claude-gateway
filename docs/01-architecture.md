# 01 — Architecture

## The two paths

> A rendered version of everything below — both paths, the policy pipeline and the
> guardrail decision flow — is in [`diagrams/architecture.drawio`](diagrams/architecture.drawio).
> Open it with draw.io or the VS Code Draw.io Integration extension. Three pages:
>
> | Page | What it shows |
> |---|---|
> | `1. Architecture` | Both paths side by side, the five inbound policy steps in order, and where each credential comes from |
> | `2. One prompt, step by step` | A single request followed down each path, including both guardrail decision points and the 403 shape |
> | `3. Why Azure's filter does not apply` | The documented citation chain behind [08 — Guardrails](08-guardrails.md#why-the-platform-filter-does-not-apply), as a diagram |

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

Lowest latency, fewest moving parts, and per-user RBAC enforced natively by Foundry. What it does *not* give you: cross-user quotas, a single audit surface, prompt/response inspection, multi-backend routing, **enforceable content guardrails** or the ability to change policy without touching clients.

The guardrail gap is the least obvious of those and the most consequential. Azure's RAI content filter does not run on this surface, so the only safety layer here is Claude's own alignment — which returns refusals as `HTTP 200` you cannot alert on. See [08 — Guardrails](08-guardrails.md).

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
      6. screen the system prompt and the last user turn as two
         separate llm-content-safety probes → 403
      7. llm-semantic-cache-lookup: answer from Redis on a close-enough prompt
      8. select the Foundry backend
      9. attach a backend credential (managed identity, or pass the caller's token through)
  → Foundry → Claude deployment
  → outbound: llm-semantic-cache-store, then stamp x-gateway and x-guardrail
  → on-error: reshape a content-safety 403 into an Anthropic-style error body
```

Every governing step is a **stock `llm-*` policy**. The gateway is the control
plane, and everything in steps 1–9 is configurable at runtime through named
values, so you can show three different security postures in a single session
without redeploying.

Steps 3, 6 and 7 are the capabilities the gateway *adds* rather than governs. Foundry's Anthropic surface answers `GET /v1/models` with `404 api_not_supported`, so Claude Desktop's **Model discovery** toggle cannot work on the direct path. The gateway answers the call itself — listing the account's Anthropic-format deployments over ARM with its own managed identity — so the client's model picker populates itself. Details in [04-claude-code-gateway.md → Model discovery](04-claude-code-gateway.md#model-discovery). Step 6 is covered below; step 7 is the semantic cache, which turns a repeated or reworded question into a Redis lookup instead of a model call.

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
| inbound | `set-body` normalisation + two `llm-content-safety` probes | **Guardrails the platform filter cannot provide for Claude** — jailbreak detection and harm severity scoring, before the model is called. Native policy; the normalisation step exists because the policy skips inspection when `system` is an array and 403s above 10,000 characters, and the system prompt is probed **separately** from the user turn because Content Safety scores a submission as a whole, so benign text dilutes the score. See [08 — Guardrails](08-guardrails.md) |
| inbound | `llm-semantic-cache-lookup` | A reworded question served from Redis for zero model tokens. After the guardrail, so a blocked prompt can never be answered from cache |
| inbound | `set-backend-service` | Backend abstraction — the seam where you would add load balancing or failover pools |
| inbound | `choose` on `{{backend-auth-mode}}` | Credential swap vs. passthrough |
| inbound | `authentication-managed-identity` | Zero stored secrets between gateway and model |
| inbound | header hygiene | The gateway credential never reaches the model backend |
| backend | `forward-request buffer-response="false"` | SSE streaming survives the hop |
| outbound | `llm-semantic-cache-store` | Populates the cache on the way out |
| outbound | `set-header x-gateway` | Visible proof the request traversed the gateway |
| outbound | `set-header x-guardrail` | Proof the guardrail check ran and allowed the prompt, rather than being skipped |
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
| `content-safety-endpoint` | AIServices account URL | Where the guardrail checks are sent |
| `content-safety-token-resource` | e.g. `https://cognitiveservices.azure.com` | Resource the gateway MI requests for Content Safety |

Use `./scripts/Set-GatewayAuthMode.ps1` to change them. Changes take effect on the next request.

Model discovery is a deploy-time switch rather than a named value, because turning it off changes which operations the policy short-circuits: `gatewayModelDiscovery` (default `true`) and `gatewayModelDiscoveryCacheSeconds` (default `300`).

Guardrails are likewise deploy-time: `gatewayGuardrails` (default `true`) and `gatewayGuardrailSeverityThreshold` (default `4`, on Content Safety's 0–7 scale).

## Guardrails, and where they are actually enforced

Worth stating plainly in an architecture doc, because it drives the design: **Azure's RAI content filter does not execute on the Anthropic surface.** `raiPolicyName` is accepted on the deployment and returned by ARM, but a custom policy blocking every harm category at the lowest threshold still lets harmful prompts reach the model. This deployment includes such a policy (`claude-strict`) specifically so the negative result is reproducible.

| Layer | Enforces | Auditable |
| --- | --- | --- |
| Gateway — native `llm-content-safety` in the inbound policy | Yes — `403` before the model is called | Yes: APIM diagnostic logs plus Application Insights |
| Platform — RAI policy on the deployment | No, for Claude | n/a |
| Model — Anthropic's own alignment | Partly | No — a refusal is `HTTP 200`, shaped like any other answer |

Content Safety is served by the **same AIServices account** that hosts the Claude deployments, on the same hostname, and `Cognitive Services User` already covers its data plane — so guardrails add no resource and no role assignment. Full evidence and tuning guidance: [08 — Guardrails](08-guardrails.md).

## Semantic cache

`llm-semantic-cache-lookup` and `llm-semantic-cache-store` are the one part of this stack that needs infrastructure of its own:

| Piece | Why |
| --- | --- |
| **Azure Managed Redis** with the RediSearch module | Vector index for prompt embeddings. RediSearch can only be enabled **at cache creation** — it is a one-way door, so a mistake means delete and recreate. |
| Registered as an APIM **external cache** | The policies read and write through APIM's cache abstraction, not a direct Redis client. External cache requires **access-key auth**; Entra to Managed Redis is not supported. |
| A **`text-embedding-3-small`** deployment on the same Foundry account | Turns each prompt into the vector that gets compared. Reached over the gateway's managed identity, like every other backend. |

`clusteringPolicy` is set to `EnterpriseCluster` rather than the Managed Redis default of `OSSCluster`, because OSS clustering needs a cluster-aware client and APIM's cache client is not one. `accessKeysAuthentication` must be explicitly `Enabled`: from API version `2025-04-01` it defaults to `Disabled`, and registering the external cache then fails with *"The ListKeys operation is not supported when access keys are disabled."* This is also why the `SecurityControl=Ignore` tag matters — without it a tenant policy re-disables the keys.

**A cache hit consumes no token budget.** The lookup happens before backend routing, so `llm-token-limit` never sees a call and `x-gateway-tokens-consumed` reads `0`. That is the intended behaviour, not a metric bug — but it will surprise you when writing tests, because a repeated prompt reports zero consumption. Use a per-run nonce in any test that needs to measure tokens.

Set `gatewaySemanticCache = false` to skip all of it. That is worth knowing: Redis is the **only standing hourly cost** in the stack besides API Management. If Managed Redis capacity is unavailable in your region — an `AllocationFailed` at create time — set `redisLocation` to a neighbouring region instead of moving the whole deployment. Capacity is per region *per SKU* and is not a quota you can raise in the portal.

## Observability

- **Application Insights** receives APIM request telemetry (`apim.bicep` logger + `apim-anthropic-api.bicep` API diagnostics) with 100% sampling and the first 8 KB of request/response bodies, which is what makes the "inspect the prompt" moment possible in a demo.
- **`llm-emit-token-metric`** publishes `Prompt Tokens`, `Completion Tokens` and `Total Tokens` in the `foundry-ai-gateway` namespace — this is the chargeback story. Three things about this are easy to get wrong:
  - The API diagnostic entity must carry **`metrics: true`**. Without it the policy runs, returns no error, and emits nothing at all. The portal does not expose the toggle; `apim-anthropic-api.bicep` sets it.
  - The counts go to the **Azure Monitor metrics store**, not to the `AppMetrics` Log Analytics table. Query them with the metrics API, not with KQL.
  - The `CallerId`, `ApiId` and `OperationId` **dimensions are dropped** until *Custom metrics (Preview) → With dimensions* is enabled on the Application Insights component. That is a portal-only setting (Application Insights → **Usage and estimated costs**); it is not expressible in Bicep and the legacy `currentbillingfeatures` API ignores it. Until you flip it, the totals are correct but you cannot split them per caller.
- **The response headers are the demo-friendly version of the same data.** `x-gateway-tokens-consumed` and `x-gateway-tokens-remaining` come from `llm-token-limit` and need no portal at all. A semantic-cache hit reports `0` consumed, because the backend was never called.
- **Foundry diagnostics** are separately available on the Cognitive Services account for the direct path.

The contrast is the point: on the direct path you can see *that* a model was called; through the gateway you can see *who* called it, *how much* it cost them, and you can stop them.

## Cost shape

| Component | Driver |
| --- | --- |
| Claude deployments | Claude Consumption Units, billed through Azure Marketplace, per token |
| API Management BasicV2 | Fixed hourly rate per scale unit — the dominant idle cost |
| Azure Managed Redis `Balanced_B0` | Fixed hourly rate. Only present when `gatewaySemanticCache = true` |
| `text-embedding-3-small` | Per token, and tiny — one embedding per cache lookup |
| Log Analytics / App Insights | Ingestion volume; body logging at 8 KB adds up under load |

For a short-lived demo, set `deployGateway = false` to skip API Management entirely if you only need the direct path, `gatewaySemanticCache = false` to skip Redis, and delete the resource group afterwards.
