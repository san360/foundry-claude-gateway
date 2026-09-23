# 02 — Deploy

## Prerequisites

| Requirement | Notes |
| --- | --- |
| Azure subscription | **Not** CSP, credit-only (Free/Azure Pass), or sponsored. Claude bills through Azure Marketplace and those subscription types cannot transact. |
| Permissions | `Owner`, or `Contributor` **plus** `User Access Administrator` — the template creates role assignments. |
| Azure CLI | 2.60+ (`az version`). Verified against 2.89.0. |
| Bicep CLI | 0.30+ (`az bicep version`). Verified against 0.46.1. |
| Region | Must offer your chosen Claude models. See below. |
| Claude Code | v2.1.0+ for Foundry support; v2.1.203+ for `ANTHROPIC_FOUNDRY_AUTH_TOKEN`. |

### Region availability

Claude model availability moves; check the Foundry portal model catalog for the current list before demoing.

| Region | Typically offers |
| --- | --- |
| `eastus2` | Haiku, Sonnet, Opus |
| `swedencentral` | Haiku, Sonnet, Opus |
| `westus2` | Sonnet, Opus |

If a deployment fails with a model-not-available error, either change `location` or clear that model parameter (set it to `''`) and redeploy.

### Marketplace agreement

The first Claude deployment in a subscription requires the Azure Marketplace offer to be accepted. If the deployment fails with a marketplace or "purchase plan" error, deploy one Claude model once from the Foundry portal to accept the terms interactively, then re-run this template.

## Configure parameters

Edit `infra/main.bicepparam`. The parameters you will actually change:

```bicep
param workloadName = 'claudedemo'          // 3-12 chars, lowercase+digits
param environmentName = 'demo'
param location = 'eastus2'

// Required: Anthropic model-provider attestation, sent with every request.
param claudeOrganizationName = 'Contoso Ltd'
param claudeCountryCode = 'US'
param claudeIndustry = 'technology'

// Models. Set to '' to skip one.
param haikuModel = 'claude-haiku-4-5'
param sonnetModel = 'claude-sonnet-4-6'
param opusModel = ''                       // Opus costs more; off by default

// Gateway
param deployGateway = true
param apimSkuName = 'BasicV2'              // v2 tier required for Anthropic schema
param apimPublisherEmail = 'you@contoso.com'
param apimPublisherName = 'Contoso'

// Auth topology (changeable later without redeploying)
param gatewayClientAuthMode = 'either'     // subscriptionKey | entra | either
param gatewayBackendAuthMode = 'managedIdentity'  // managedIdentity | passthrough
param disableFoundryLocalAuth = false      // flip to true for the keyless demo
param allowLocalAuthExemption = true       // SecurityControl=Ignore; without it, policy forces keys off
```

Full parameter reference:

| Parameter | Default | Purpose |
| --- | --- | --- |
| `workloadName` | `claudedemo` | Name prefix |
| `environmentName` | `demo` | Name suffix |
| `location` | `eastus2` | Region for everything |
| `resourceGroupName` | `rg-<workload>-<env>` | Resource group to create |
| `tags` | workload/environment/solution | Applied to every resource |
| `haikuModel` / `sonnetModel` / `opusModel` | `claude-haiku-4-5` / `claude-sonnet-4-6` / `''` | Model IDs; `''` skips |
| `haikuCapacity` / `sonnetCapacity` / `opusCapacity` | 10 / 25 / 25 | Thousands of TPM |
| `modelVersion` | `'2'` | `'2'` Hosted on Azure, `'1'` Hosted on Anthropic |
| `claudeOrganizationName` | *(required)* | Legal entity name |
| `claudeCountryCode` | `US` | Two-letter code |
| `claudeIndustry` | `technology` | One of the allowed lowercase values |
| `principalId` | `''` | Object ID granted `Cognitive Services User` |
| `principalType` | `User` | `User`, `ServicePrincipal` or `Group` |
| `disableFoundryLocalAuth` | `false` | Turns off Foundry API keys entirely |
| `allowLocalAuthExemption` | `true` | Tags every resource `SecurityControl=Ignore`. Tenant policy forces `disableLocalAuth = true` on Cognitive Services accounts without this tag, which makes the key-based scenarios undeployable. Demo only — never set it on production. |
| `deployGateway` | `true` | Set `false` for a direct-path-only deployment |
| `apimSkuName` | `BasicV2` | `BasicV2`, `StandardV2`, `PremiumV2` |
| `apimSkuCapacity` | `1` | Scale units |
| `apimPublisherEmail` / `apimPublisherName` | Contoso placeholders | Required by API Management |
| `gatewayClientAuthMode` | `either` | Client auth posture |
| `gatewayBackendAuthMode` | `managedIdentity` | Backend auth posture |
| `gatewayEntraAudience` | `https://ai.azure.com` | Expected `aud` claim |
| `foundryTokenResource` | `https://ai.azure.com` | Resource the gateway MI requests |
| `gatewayTokensPerMinute` | `20000` | Per-caller TPM budget before 429 |
| `gatewaySubscriptionKeyHeader` | `x-api-key` | Header carrying the APIM subscription key. `x-api-key` is Anthropic's own convention, is what the Foundry Anthropic endpoint expects, and is one of only two schemes Claude Desktop can send — so one header name works everywhere. |
| `gatewayBodyLogBytes` | `8192` | Bytes of request/response body logged to Application Insights. `0` disables it. |
| `gatewayModelDiscovery` | `true` | Answer `GET /v1/models` from ARM, which Foundry's Anthropic surface cannot do |
| `gatewayGuardrails` | `true` | Master switch for `llm-content-safety` |
| `gatewayGuardrailSeverityThreshold` | `4` | Block at or above this severity, on Content Safety's 0–7 scale |
| `gatewaySemanticCache` | `true` | Deploys Azure Managed Redis and enables `llm-semantic-cache-*`. Set `false` to remove the only standing hourly cost besides API Management. |
| `gatewaySemanticCacheScoreThreshold` | `'0.05'` | Vector **distance**, so lower is stricter. Raise it to serve more from cache, at the risk of answering a question the caller did not ask. |
| `gatewaySemanticCacheDurationSeconds` | `120` | How long a cached completion stays valid |
| `redisSkuName` | `Balanced_B0` | Managed Redis size backing the cache |
| `redisLocation` | `''` (same as `location`) | **Escape hatch for capacity.** See below. |
| `embeddingModel` | `text-embedding-3-small` | Deployed on the same Foundry account; vectorises prompts for the cache |

> **`AllocationFailed` on Azure Managed Redis.** Managed Redis capacity is
> allocated per region *per SKU*, and a busy region refuses the create — we hit
> this on `eastus2`, at both `Balanced_B0` and `Balanced_B1`, while `eastus` and
> `westus2` provisioned the same SKU without complaint. It is not a quota you can
> raise from the portal. Set `redisLocation` to a neighbouring region rather than
> moving the whole stack; the external cache is registered with
> `useFromLocation: 'default'`, so cross-region works and costs a few
> milliseconds on a cache hit. Alternatively set `gatewaySemanticCache = false`.
>
> Budget **20–40 minutes** for the Redis create either way. It is the slowest
> resource in the deployment after API Management, and it fails *slowly* too — an
> allocation failure took about six minutes to surface.

## Deploy

```powershell
az login
az account set --subscription "<your subscription>"

# Preview first (recommended)
./scripts/deploy.ps1 -Location eastus2 -GrantSelfAccess -WhatIf

# Deploy
./scripts/deploy.ps1 -Location eastus2 -GrantSelfAccess
```

`-GrantSelfAccess` resolves your signed-in object ID and passes it as `principalId`, so the Entra path works the moment the deployment finishes.

Once the ARM deployment lands, `deploy.ps1` provisions the Content Safety
blocklist named by `gatewayGuardrailBlocklistName` before it reports success.
That step is not optional: the gateway policy references the blocklist by name,
and a name that does not exist makes Content Safety return **HTTP 400 on every
request**. If you deploy with raw `az deployment` instead of the script, run
`./scripts/Set-ContentSafetyBlocklist.ps1 -Verify` yourself. See
[08 — Guardrails](08-guardrails.md#when-the-classifiers-score-zero-the-blocklist).

Or without the helper script:

```bash
az deployment sub create \
  --name claude-foundry \
  --location eastus2 \
  --template-file infra/main.bicep \
  --parameters infra/main.bicepparam \
  --parameters principalId=$(az ad signed-in-user show --query id -o tsv)
```

### How long it takes

| Phase | Duration |
| --- | --- |
| Log Analytics + Application Insights | ~1 minute |
| **API Management (v2 tier) creation** | **15–45 minutes** — dominates everything |
| Foundry account + project | ~2 minutes |
| Each Claude deployment | ~1–2 minutes, serialized |
| API, policy, named values | ~2 minutes |

Deploying with `deployGateway = false` completes in about five minutes. Re-deploying over an existing API Management instance takes only a few minutes, so iterate on policy changes freely.

## Outputs

`scripts/deploy.ps1` writes `.deployment-outputs.json` at the repository root. Every other script reads it.

| Output | Used for |
| --- | --- |
| `resourceGroupName` | Key lookups, teardown |
| `foundryAccountName` | `ANTHROPIC_FOUNDRY_RESOURCE` |
| `foundryAnthropicBaseUrl` | Direct base URL |
| `foundryProjectEndpoint` | Foundry SDK / portal |
| `gatewayAnthropicBaseUrl` | `ANTHROPIC_FOUNDRY_BASE_URL` for the gateway path |
| `apimName` | Subscription key lookup, named-value updates |
| `gatewaySubscriptionName` | Subscription key lookup |
| `gatewaySubscriptionKeyHeader` | Which header to send the key on |
| `haikuDeploymentName` / `sonnetDeploymentName` / `opusDeploymentName` | Model pinning |
| `gatewayGuardrailBlocklistName` | Content Safety blocklist to provision post-deploy |
| `appInsightsName` | Telemetry queries |

The API Management subscription key is deliberately **not** a template output — outputs are stored in deployment history in clear text. Retrieve it on demand:

```powershell
az rest --method post --uri "/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.ApiManagement/service/<apim>/subscriptions/claude-code-demo/listSecrets?api-version=2024-05-01" --query primaryKey -o tsv
```

`scripts/Set-ClaudeCodeEnv.ps1 -Auth Key` does this for you.

## Verify

```powershell
./scripts/Test-ClaudeEndpoint.ps1 -Mode Direct  -Auth Entra
./scripts/Test-ClaudeEndpoint.ps1 -Mode Direct  -Auth Key
./scripts/Test-ClaudeEndpoint.ps1 -Mode Gateway -Auth Key
./scripts/Test-ClaudeEndpoint.ps1 -Mode Gateway -Auth Entra
```

A successful gateway call prints `x-gateway: azure-api-management` and `x-gateway-tokens-remaining`, which proves both the hop and the token governance.

## Validate changes locally

```powershell
az bicep build --file infra/main.bicep --stdout > $null   # must be silent
az bicep build-params --file infra/main.bicepparam --stdout > $null
[xml](Get-Content infra/policies/anthropic-api.xml -Raw)  # must parse
```

The policy XML is embedded by `loadTextContent`, so a malformed policy fails the deployment rather than the build. Always parse it locally first. Two rules bite repeatedly:

- XML comments **cannot contain `--`**.
- C# string literals inside policy **attributes** must be escaped as `&quot;`. Element *content* does not need escaping.

## Tear down

```powershell
az group delete --name rg-claudedemo-demo --yes --no-wait
```

API Management soft-deletes. To reuse the same name immediately:

```powershell
az apim deletedservice purge --service-name <apim-name> --location eastus2
```

The Foundry account also soft-deletes:

```powershell
az cognitiveservices account purge --name <account> --resource-group <rg> --location eastus2
```
