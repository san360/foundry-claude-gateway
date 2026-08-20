# 07 — Troubleshooting

## Diagnose in this order

1. Does the **raw HTTP** call work? `./scripts/Test-ClaudeEndpoint.ps1`. If it fails, the problem is Azure, not Claude Code.
2. Is it **direct or gateway**? Test direct first; if direct fails, gateway cannot work.
3. Is it **auth or routing**? `401`/`403` is auth; `404`/`405` is routing or a wrong model name.
4. Only then look at Claude Code environment variables.

## Deployment

### `InvalidTemplateDeployment` / marketplace or purchase-plan error

The Azure Marketplace agreement for Claude has not been accepted on this subscription. Deploy one Claude model once from the Foundry portal to accept the terms interactively, then re-run the template. Also confirm the subscription is not CSP, credit-only or sponsored — those cannot transact Marketplace offers.

### `The model 'claude-...' is not available in region '...'`

Region/model mismatch. Change `location`, or set that model parameter to `''` and redeploy. Check the Foundry portal model catalog for current availability — it changes.

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
