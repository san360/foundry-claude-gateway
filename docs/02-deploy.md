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
| `deployGateway` | `true` | Set `false` for a direct-path-only deployment |
| `apimSkuName` | `BasicV2` | `BasicV2`, `StandardV2`, `PremiumV2` |
| `apimSkuCapacity` | `1` | Scale units |
| `apimPublisherEmail` / `apimPublisherName` | Contoso placeholders | Required by API Management |
| `gatewayClientAuthMode` | `either` | Client auth posture |
| `gatewayBackendAuthMode` | `managedIdentity` | Backend auth posture |
| `gatewayEntraAudience` | `https://ai.azure.com` | Expected `aud` claim |
| `foundryTokenResource` | `https://ai.azure.com` | Resource the gateway MI requests |
| `gatewayTokensPerMinute` | `20000` | Per-caller TPM budget before 429 |
| `gatewaySubscriptionKeyHeader` | `api-key` | Header carrying the APIM subscription key |
| `gatewayBodyLogBytes` | `8192` | Bytes of request/response body logged to Application Insights. `0` disables it. |

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
