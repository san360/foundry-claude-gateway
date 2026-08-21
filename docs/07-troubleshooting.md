# 07 — Troubleshooting

## Diagnose in this order

1. Does the **raw HTTP** call work? `./scripts/Test-ClaudeEndpoint.ps1`. If it fails, the problem is Azure, not Claude Code.
2. Is it **direct or gateway**? Test direct first; if direct fails, gateway cannot work.
3. Is it **auth or routing**? `401`/`403` is auth; `404`/`405` is routing or a wrong model name.
4. Only then look at Claude Code environment variables.

## Deployment

### `InvalidTemplateDeployment` / marketplace or purchase-plan error

The Azure Marketplace agreement for Claude has not been accepted on this subscription. Deploy one Claude model once from the Foundry portal to accept the terms interactively, then re-run the template. Also confirm the subscription is not CSP, credit-only or sponsored — those cannot transact Marketplace offers.

### `Marketplace purchases are disabled for this subscription due to policy restrictions`

Verified failure mode. The full error is:

```
UserError: Error occurred when subscribing to Marketplace: Marketplace Subscription
purchase eligibility check failed ... This subscription is internal or sandbox.
Only $0.00 products or test products can be purchased ... Marketplace purchases are
disabled for this subscription '<id>' due to policy restrictions.
```

Claude on Foundry is a Marketplace offer, so **internal, sandbox and monetary-credit subscriptions cannot deploy it at all**. There is no template workaround — you must use a subscription with a real payment instrument.

This failure is late and misleading: Log Analytics, Application Insights, the Foundry account *and* the project all report `Succeeded`, and only the `Microsoft.CognitiveServices/accounts/deployments` resource fails. Do not read the partially-created resource group as a template defect.

Confirm eligibility before a long deployment:

```powershell
az account show --query "{name:name, id:id}" -o json
# then probe cheaply: one model, capacity 1, no gateway
az deployment sub create --name probe --location eastus2 `
  --template-file infra/main.bicep --parameters infra/main.bicepparam `
  --parameters workloadName=probe sonnetModel='' opusModel='' `
  --parameters haikuCapacity=1 deployGateway=false
```

### `Failed to list key. disableLocalAuth is set to be true`

Verified failure mode. Returned by `az cognitiveservices account keys list` even when the template sets `disableFoundryLocalAuth = false`.

Many enterprise and Microsoft-internal tenants attach an Azure Policy with a `modify` effect that forces `properties.disableLocalAuth = true` on every Cognitive Services account. The policy wins: ARM reports your deployment as `Succeeded` with the value you asked for, but the live resource has `true`.

Check what actually landed rather than what you requested:

```powershell
az cognitiveservices account show -n <account> -g <rg> `
  --query properties.disableLocalAuth
```

If it returns `true`, API keys are unavailable on that account and every key-based call returns `401`.

**The fix: tag the account `SecurityControl=Ignore`.** That is the tenant's own exemption tag, and the policy skips any resource carrying it. The template applies it by default:

```bicep
// infra/main.bicepparam
param allowLocalAuthExemption = true   // adds SecurityControl=Ignore to every resource
param disableFoundryLocalAuth = false
```

Verify what landed:

```powershell
az cognitiveservices account show -n <account> -g <rg> `
  --query "{localAuth:properties.disableLocalAuth, tags:tags}"
# expected: localAuth = false, tags.SecurityControl = "Ignore"
```

> **The tag is evaluated at create *and* update.** Redeploying an already-hardened account with the tag does flip `disableLocalAuth` back to `false` — verified on this deployment, where an account created without the tag went from `true` to `false` on the next `deploy.ps1` run. If yours does not flip, the account predates the tag and the safest fix is to delete the resource group and redeploy; that also gets you a clean set of model deployments.

Do not set this on a production workload. It is a demo exemption, and the Entra path remains the recommended configuration:

- Direct: unset `ANTHROPIC_FOUNDRY_API_KEY` and let Claude Code use `DefaultAzureCredential`, or supply `ANTHROPIC_FOUNDRY_AUTH_TOKEN`. See [03-claude-code-direct.md](03-claude-code-direct.md).
- Gateway: keep `gatewayBackendAuthMode = 'managedIdentity'` (the default). A `passthrough` backend cannot work against a key-disabled account unless the caller presents an Entra token.

A telltale sign in the deployment list is a system-injected `PolicyDeployment_<digits>` entry:

```powershell
az deployment group list -g <rg> --query "[].name" -o tsv
```

### `401` with a valid Foundry key on the direct path

Wrong header. The **Anthropic** surface of a Foundry account expects Anthropic's own `x-api-key`; it rejects `api-key` and `Ocp-Apim-Subscription-Key` with the misleading message *"Access denied due to invalid subscription key or wrong API endpoint"*. The Azure OpenAI surface of the *same* account does accept `api-key`, which is where the confusion comes from.

```powershell
# works
curl -X POST "https://<account>.services.ai.azure.com/anthropic/v1/messages" `
  -H "x-api-key: <key>" -H "anthropic-version: 2023-06-01" ...
```

Claude Code and Claude Desktop set the header for you — this only bites when hand-rolling a request. The gateway's subscription key header now defaults to `x-api-key` for the same reason.

### `The model 'claude-...' is not available in region '...'`

Region/model mismatch. Change `location`, or set that model parameter to `''` and redeploy. Check the Foundry portal model catalog for current availability — it changes.

### Model version mismatch — `haikuModelVersion` / `sonnetModelVersion` / `opusModelVersion`

Verified failure mode. **Claude model versions on Foundry are not uniform across families**, which is why the template exposes one version parameter per family instead of a single global one.

Measured in `eastus2`, version `2` means "hosted on Azure" and version `1`/`<date>` means the partner-hosted variant:

| Model | Versions published |
|---|---|
| `claude-haiku-4-5` | `20251001`, `2` |
| `claude-sonnet-4-6` | `1` only — **no version 2** |
| `claude-opus-4-8` | `1`, `2` |

Pinning `2` for every family therefore fails on `claude-sonnet-4-6`. Always check before deploying:

```powershell
az cognitiveservices model list --location eastus2 `
  --query "[?model.format=='Anthropic'].{name:model.name, version:model.version}" -o table
```

Quota is tracked per version, and a `.Azure` suffix in the quota name is the version-2 counter. A limit of `0` means the model cannot be deployed on that subscription no matter what capacity you request:

```powershell
az cognitiveservices usage list --location eastus2 `
  --query "[?contains(name.value,'laude')].{name:name.value, limit:limit, used:currentValue}" -o table
```

`capacity` on a deployment is expressed in the same units as `limit` (thousands of tokens per minute).

### HTTP 409 on a deployment

Foundry serializes model deployments under one account. The template already chains them with `dependsOn`; if you added a deployment, chain it too.

### API Management creation takes forever

15–45 minutes is normal for a first v2-tier create. Subsequent deployments to the same instance take a couple of minutes. Use `deployGateway = false` while iterating on the Foundry side.

### `BCP037: modelProviderData is not allowed`

Expected. The property is valid in ARM but not yet in the Bicep type definitions. `#disable-next-line BCP037` is already applied above each occurrence in `foundry.bicep`.

### Policy deployment fails with a validation error

The policy XML is embedded by `loadTextContent`, so defects surface at deployment time. Parse locally first:

```powershell
[xml](Get-Content infra/policies/anthropic-api.xml -Raw)
```

Two rules cause almost every failure:

- **XML comments cannot contain `--`.** Divider comments like `<!-- ------ -->` are invalid.
- **C# string literals inside XML attributes must be escaped as `&quot;`.** For example `condition="@(&quot;{{client-auth-mode}}&quot; == &quot;entra&quot;)"`. Element *content* such as `<value>@("Bearer " + x)</value>` does **not** need escaping.

Also: every `{{named-value}}` referenced by the policy must exist before the policy is applied. The `apiPolicy` resource has an explicit `dependsOn` covering all named values, the backend and every operation.

### Name already exists after deleting the resource group

API Management and Cognitive Services both soft-delete.

```powershell
az apim deletedservice purge --service-name <apim-name> --location <region>
az cognitiveservices account purge --name <account> --resource-group <rg> --location <region>
```

## Direct path

### `401 Unauthorized` with an Entra token

| Cause | Check |
| --- | --- |
| Missing role | `az role assignment list --assignee <oid> --scope <account-resource-id>` — need `Cognitive Services User`. |
| RBAC not propagated | Wait 5–10 minutes after deployment. |
| Wrong token resource | Token must be for `https://ai.azure.com`, not `https://cognitiveservices.azure.com`. |
| Wrong tenant | `az account show --query tenantId` must match the Foundry account's tenant. |
| Stale token | `az account get-access-token` again; tokens last about an hour. |

Decode the token and check `aud`, `tid` and `oid` — see the snippet at the end of [05 — Entra authentication](05-entra-authentication.md).

### `401 Unauthorized` with an API key

Most likely `disableFoundryLocalAuth = true`. The keys API still returns strings but the service rejects them. Use `-Auth Entra`. Confirm:

```powershell
az cognitiveservices account show -n <account> -g <rg> --query properties.disableLocalAuth
```

### `403 Forbidden`

The credential is valid but not authorized. Usually the role is assigned at the wrong scope (subscription vs. account) or to the wrong object ID — for a managed identity you need the **principal/object ID**, not the client ID or resource ID.

### `404 Not Found` on `/v1/messages`

| Cause | Fix |
| --- | --- |
| `model` is the model ID, not the deployment name | Use the value from `.deployment-outputs.json`. This is the most common failure. |
| Base URL missing `/anthropic` | `ANTHROPIC_FOUNDRY_BASE_URL` must include it; `ANTHROPIC_FOUNDRY_RESOURCE` adds it for you. |
| Deployment not finished | Check the Foundry portal deployments blade. |

### `429 Too Many Requests` directly from Foundry

Deployment capacity exceeded. Raise `haikuCapacity`/`sonnetCapacity` (thousands of TPM) and redeploy, or slow the client. This is distinct from a gateway 429, which carries `x-gateway-tokens-remaining`.

### Missing `anthropic-version` header

Foundry requires it. Claude Code and the SDKs send it automatically; hand-written curl calls must include `anthropic-version: 2023-06-01`. The gateway policy adds it as a default if absent.

## Gateway path

### `401 Access denied due to missing subscription key`

API Management did not find the key on the expected header. The API is configured for `api-key` by default.

```powershell
# What header is expected?
(Get-Content .deployment-outputs.json | ConvertFrom-Json).gatewaySubscriptionKeyHeader
```

If Claude Code is sending `x-api-key` instead, redeploy with `gatewaySubscriptionKeyHeader = 'x-api-key'`. **You cannot fix this in policy** — API Management validates the subscription key before inbound policy execution, so a `set-header` rename runs too late. Alternatively set `gatewayClientAuthMode = 'entra'` and stop using subscription keys.

### `401` from `validate-azure-ad-token`

| Cause | Check |
| --- | --- |
| Audience mismatch | Token `aud` must equal `{{entra-audience}}`. `./scripts/Set-GatewayAuthMode.ps1 -Show`. |
| Tenant mismatch | Token `tid` must equal `{{entra-tenant-id}}`. |
| Expired token | Re-acquire; static tokens are not refreshed by Claude Code. |
| `client-auth-mode = entra` but no token sent | Set it to `either`, or supply a token. |

### `401` from Foundry *behind* the gateway

Look at the `x-gateway-error` response header first.

- `backend-auth-mode = managedIdentity`: the gateway's managed identity is missing `Cognitive Services User` on the Foundry account. Confirm the identity exists and the assignment is present:

  ```powershell
  $mi = az apim show -n <apim> -g <rg> --query identity.principalId -o tsv
  az role assignment list --assignee $mi --scope <foundry-account-resource-id> -o table
  ```

- `backend-auth-mode = passthrough`: the caller's token is being forwarded, so **the caller** needs `Cognitive Services User` — and the caller must actually be sending a token. Subscription-key-only callers cannot work in passthrough mode. Either grant the user the role or switch back to `managedIdentity`.

### `429` from the gateway

Expected behaviour: the per-caller `llm-token-limit` budget is spent. Check `x-gateway-tokens-remaining` and `Retry-After`. Raise `gatewayTokensPerMinute` and redeploy if the limit is too tight for real use. Note the counter key is the Entra `oid` when a token is present and the API Management subscription ID otherwise — switching auth mode mid-demo resets which bucket you are consuming.

### Streaming appears broken / responses arrive all at once

`buffer-response="false"` is missing from `<forward-request>` in the effective policy. Confirm the deployed policy in the portal (APIM → APIs → anthropic → Design → All operations → Inbound/Backend) matches the repo file.

### Long requests time out

`timeout="240"` is the maximum for the `forward-request` attribute. For turns longer than that, reduce `MAX_THINKING_TOKENS` / `CLAUDE_CODE_MAX_OUTPUT_TOKENS`, or split the work.

### The `x-gateway` header is absent

The request did not go through API Management. Check `ANTHROPIC_FOUNDRY_BASE_URL` — a stale `ANTHROPIC_FOUNDRY_RESOURCE` takes an entirely different route. The helper script clears one when setting the other.

## Claude Code

### `/status` shows `Anthropic API` instead of `Microsoft Foundry`

`CLAUDE_CODE_USE_FOUNDRY` was not in the process environment at launch. The desktop app inherits from its launch environment, so variables set in a terminal afterwards do not apply. Fully quit the app, set the variables (or use the machine/user-scoped approach in [03](03-claude-code-direct.md)), then relaunch.

### It still uses a key even though you want Entra

`ANTHROPIC_FOUNDRY_API_KEY` outranks the credential chain, and `ANTHROPIC_FOUNDRY_AUTH_TOKEN` outranks both. Unset them:

```powershell
Remove-Item Env:ANTHROPIC_FOUNDRY_API_KEY, Env:ANTHROPIC_FOUNDRY_AUTH_TOKEN -ErrorAction SilentlyContinue
```

### `ANTHROPIC_FOUNDRY_AUTH_TOKEN` is ignored

Requires Claude Code **v2.1.203+**. Check with `claude --version`.

### A model error appears mid-conversation, not at startup

Model aliases were not pinned and Claude Code resolved one to a deployment that does not exist. There is no startup validation. Set `ANTHROPIC_DEFAULT_SONNET_MODEL`, `ANTHROPIC_DEFAULT_HAIKU_MODEL` and, if you deployed it, `ANTHROPIC_DEFAULT_OPUS_MODEL`. If you did not deploy Opus, point that variable at your Sonnet deployment so `/model opus` degrades instead of failing.

### `/logout` does nothing

Expected — `/logout` is unavailable in Foundry mode. Credential lifetime is managed by Azure, not Claude Code. Use `az logout`.

### Both `ANTHROPIC_FOUNDRY_RESOURCE` and `ANTHROPIC_FOUNDRY_BASE_URL` are set

Undefined precedence. Always set exactly one. The helper scripts clear the other.

## Claude Desktop

### Settings changes have no effect

Claude Desktop reads configuration **once, at launch**. Quit it completely — including the system tray icon on Windows and *Quit* rather than closing the window on macOS — then reopen it.

### `AADSTS700016: Application with identifier '<guid>' was not found in the directory`

The tenant ID was typed into the **Client ID** box. Anthropic's own documentation screenshot shows exactly this mistake. They are different GUIDs:

- `inferenceFoundryTenantId` — the directory ID,
- `inferenceFoundryClientId` — the **application (client) ID** of the app registration.

`Set-ClaudeDesktopConfig.ps1` refuses to write a config where the two are equal.

### `Need admin approval` — "Claude Desktop - Microsoft Foundry needs permission to access resources in your organisation that only an admin can grant"

Verified failure mode, and the reason this repo supports key-based auth as a first-class scenario.

The app registration requests delegated `user_impersonation` on Azure Cognitive Services. That scope is nominally user-consentable, but many tenants disable self-service consent outright (*Enterprise applications → Consent and permissions → Do not allow user consent*). When they do, **every** delegated permission needs an admin grant, regardless of the scope's own consent setting. If you are not a directory admin, you cannot proceed on the Entra path.

Three options, in order of practicality:

1. **Use the key scenario instead.** No app registration, no consent, no directory admin:

   ```powershell
   ./scripts/New-ClaudeConfig.ps1 -Mode Direct -CredentialKind static -Apply
   ```

   This needs `disableLocalAuth = false` on the Foundry account — see the `SecurityControl=Ignore` entry above.

2. **Ask a Global Administrator or Cloud Application Administrator to grant consent once**, then Entra works for every user in the tenant:

   ```powershell
   ./scripts/New-FoundryAppRegistration.ps1 -GrantAdminConsent
   ```

   Or send them the admin consent URL:

   ```
   https://login.microsoftonline.com/<tenant-id>/adminconsent?client_id=<app-client-id>
   ```

3. **Use Claude Code instead of Claude Desktop for the Entra demo.** The CLI authenticates as a Microsoft first-party client through `az login`, so it needs no app registration and no consent at all. This is why `Test-ClaudeEndpoint.ps1 -Auth Entra` succeeds while the desktop app is still blocked.

Note that consent is only half the story. Even after an admin grants it, the user still needs the **Cognitive Services User** role on the Foundry account, or every call returns `403`.

### `AADSTS50011: The redirect URI specified in the request does not match`

Entra wildcards the **port** of a `127.0.0.1` redirect but not the **path**. `browser` flow needs `http://127.0.0.1/callback` registered; a bare `http://127.0.0.1` is not a match. Re-run `New-FoundryAppRegistration.ps1`, which registers all three flows' URIs.

### `AADSTS7000218` / device-code flow rejected

`isFallbackPublicClient` is false on the app registration. Public client flows must be enabled. `New-FoundryAppRegistration.ps1` sets this.

### Sign-in succeeds but every request returns 403

Signing in only proves identity. Calling the model needs the **Cognitive Services User** role on the Foundry account. `deploy.ps1 -GrantSelfAccess` grants it to the deploying user only — grant it separately to anyone else in the demo.

### The registry policy is written but ignored

In order of how often it bites:

1. **`HKCU\SOFTWARE\Policies` is ACL'd read-only for standard users.** Writing it needs an elevated shell, in *both* hives. If you don't want elevation, use `-ApplyTarget Local`, which writes the per-user profile library instead.
2. **An HKLM policy exists.** If it does, HKCU is ignored **entirely** — the two are not merged.
3. **Wrong value type.** Values must be `REG_SZ`. `REG_EXPAND_SZ` reads as "present but unreadable"; `REG_QWORD`, `REG_MULTI_SZ` and `REG_BINARY` are invisible.
4. **Values in a subkey.** They must sit directly under `…\Anthropic\Claude`.
5. **Numbers or booleans written unquoted.** Under policy *everything* is a string, including `86400` and `false`. The local profile library is the opposite — native JSON types. `Set-ClaudeDesktopConfig.ps1` handles both.

### Gateway mode: `401` from `validate-azure-ad-token` even though sign-in worked

The audience. Claude Desktop's gateway provider signs in with **your** app registration, and a custom app registration cannot request `https://ai.azure.com` — that resource has no enumerable service principal in the tenant, so it cannot be added as a required resource.

Use `https://cognitiveservices.azure.com/.default` in `inferenceGatewayOidc.scopes`, and make sure the gateway accepts it:

```powershell
az apim nv show -g <rg> --service-name <apim> --named-value-id entra-audience-alt --query value -o tsv
# expected: https://cognitiveservices.azure.com
```

If it is missing, redeploy — `gatewayEntraAudienceAdditional` defaults to that value and the deployment output `gatewayEntraAudiences` should list both.

This is safe only under `backendAuthMode = 'managedIdentity'`, where the policy replaces the caller's token with the gateway's managed-identity token before calling Foundry. Under `passthrough` the caller's token reaches Foundry and must be `aud: https://ai.azure.com`, so **passthrough cannot serve Claude Desktop's gateway sign-in**.

### Gateway mode: device-code is not offered

`inferenceGatewayOidcAuthFlow` accepts `browser` and `broker` only. Device code exists on the Foundry provider, not the gateway provider.

### Gateway settings appear to be ignored

Check `inferenceProvider`. The Foundry keys (`inferenceFoundry*`) and the gateway keys (`inferenceGateway*`) belong to two different providers; whichever `inferenceProvider` names, the other block is discarded. Don't try to point the Foundry provider at the gateway URL — it has no base-URL setting.

### The model picker is empty or missing a model

`modelDiscoveryEnabled` must be `false`: Foundry exposes no Anthropic model-listing endpoint, so discovery returns nothing and the app shows an empty list. `inferenceModels` is then authoritative, and each entry's `name` must be the **Foundry deployment name** — not the upstream Anthropic model ID:

```json
[{"name":"claude-sonnet-4-6","labelOverride":"claude-sonnet-4-6","anthropicFamilyTier":"sonnet"}]
```

`anthropicFamilyTier` drives the app's own sonnet/haiku routing; omit it and the model may never be selected automatically.

## Deployment scripts

### `InvalidPrincipalId`, with the GUID followed by extra text

Azure CLI concatenates values that follow a **repeated** `--parameters` switch into the *preceding* parameter, so `principalId` arrives as `"<guid> principalType=User"`. Put every inline override after a **single** `--parameters`:

```powershell
# wrong
az deployment group create --parameters a=1 --parameters b=2
# right
az deployment group create --parameters a=1 b=2
```

Fixed in `deploy.ps1`.

### `.deployment-outputs.json` points at resources that no longer exist

Every helper script reads that file. If the resource group was deleted out of band, the file goes stale and the scripts fail against deleted resources. Re-run `deploy.ps1`; it rewrites the file. Then regenerate the client config, which is derived from it:

```powershell
./scripts/New-ClaudeConfig.ps1 -Mode Direct -ClientId <app-client-id> -Apply
```

### Deploying into an Entra External / MCAPS trial subscription

Anthropic models are Marketplace offerings. External-tenant and many trial subscriptions carry a Marketplace purchase policy that blocks the offer acquisition, and the failure surfaces as a template error rather than a policy one. This is not fixable from the template — private Marketplace stores and quota ID changes do not lift it. Deploy into a subscription without the restriction.

## Useful queries

**Gateway failures in the last hour**

```kusto
requests
| where timestamp > ago(1h) and success == false
| project timestamp, name, resultCode, duration, customDimensions
| order by timestamp desc
```

**Token spend by caller**

```kusto
customMetrics
| where name == "Total Tokens" and timestamp > ago(24h)
| extend caller = tostring(customDimensions["CallerId"])
| summarize tokens = sum(value) by caller
| order by tokens desc
```

**Throttled callers**

```kusto
requests
| where resultCode == 429 and timestamp > ago(6h)
| summarize count() by bin(timestamp, 10m)
| render timechart
```

## Sanity checklist

```powershell
# Identity
az account show --query "{user:user.name, tenant:tenantId, sub:name}"

# Foundry account state
az cognitiveservices account show -n <account> -g <rg> `
  --query "{endpoint:properties.endpoint, localAuth:properties.disableLocalAuth, state:properties.provisioningState}"

# Deployments
az cognitiveservices account deployment list -n <account> -g <rg> `
  --query "[].{name:name, model:properties.model.name, state:properties.provisioningState}" -o table

# Your roles on the account
az role assignment list --assignee $(az ad signed-in-user show --query id -o tsv) `
  --scope $(az cognitiveservices account show -n <account> -g <rg> --query id -o tsv) -o table

# Gateway identity and its roles
$mi = az apim show -n <apim> -g <rg> --query identity.principalId -o tsv
az role assignment list --assignee $mi -o table

# Effective auth topology
./scripts/Set-GatewayAuthMode.ps1 -Show

# Current Claude Code environment
Get-ChildItem Env: | Where-Object Name -match 'ANTHROPIC|CLAUDE'
```
