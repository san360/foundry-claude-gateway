# 05 — Microsoft Entra ID authentication

> **Short answer to "can we use Entra for both scenarios?" — Yes, for both, and in the gateway case in two different topologies. Neither path requires an API key at any point. You can deploy this template with `disableFoundryLocalAuth = true` and have no usable key anywhere in the system.**

## The matrix

| # | Path | Client credential | Gateway → Foundry credential | Foundry sees | Supported |
| --- | --- | --- | --- | --- | --- |
| 1 | Direct | Foundry API key | — | shared key | ✓ |
| 2 | **Direct** | **Entra token (`DefaultAzureCredential`)** | — | **the end user** | **✓ recommended** |
| 3 | Direct | Entra token (`ANTHROPIC_FOUNDRY_AUTH_TOKEN`) | — | the end user / SPN | ✓ |
| 4 | Gateway | APIM subscription key | gateway managed identity | the gateway | ✓ |
| 5 | **Gateway** | **Entra token, validated at the edge** | **gateway managed identity** | **the gateway** | **✓ recommended** |
| 6 | Gateway | Entra token, validated at the edge | same token passed through | **the end user** | ✓ |
| 7 | Gateway | APIM subscription key | passthrough | *(no bearer token)* | ✗ invalid combination |

Rows 2, 5 and 6 are entirely key-free.

## Scenario A — Direct: Claude Code → Foundry with Entra

### How it works

Claude Code, when neither `ANTHROPIC_FOUNDRY_API_KEY` nor `ANTHROPIC_FOUNDRY_AUTH_TOKEN` is set, falls back to the **Azure SDK default credential chain** — Azure CLI, Azure PowerShell, environment variables, Managed Identity, Workload Identity, Visual Studio, and so on. It requests a token for the Foundry Anthropic resource and sends it as `Authorization: Bearer <token>`. Foundry validates it and evaluates **Azure RBAC** on the Cognitive Services account.

```powershell
az login
$env:CLAUDE_CODE_USE_FOUNDRY = '1'
$env:ANTHROPIC_FOUNDRY_RESOURCE = '<account>'
# Deliberately no key variable set.
claude
```

Equivalent raw call:

```powershell
$token = az account get-access-token --resource https://ai.azure.com --query accessToken -o tsv
curl "https://<account>.services.ai.azure.com/anthropic/v1/messages" `
  -H "Authorization: Bearer $token" `
  -H "anthropic-version: 2023-06-01" `
  -H "Content-Type: application/json" `
  -d '{"model":"claude-sonnet-4-6","max_tokens":100,"messages":[{"role":"user","content":"hi"}]}'
```

### Token resource / scope

| Context | Value |
| --- | --- |
| Azure CLI | `az account get-access-token --resource https://ai.azure.com` |
| SDK scope | `https://ai.azure.com/.default` |

> The **generic** Foundry model-inference surface documents `https://cognitiveservices.azure.com/.default`. The **Anthropic** surface documents `https://ai.azure.com`. This template uses `https://ai.azure.com` everywhere and exposes it as the `foundryTokenResource` and `gatewayEntraAudience` parameters, so you can change it in one place if your tenant or a future service update requires the other value.

### Required RBAC

| Role | Role definition ID | Grants |
| --- | --- | --- |
| **Cognitive Services User** | `a97b65f3-24c7-4388-baec-2e87135dc908` | `Microsoft.CognitiveServices/accounts/MaaS/*` — inference. **Least privilege; use this.** |
| Cognitive Services Contributor | `25fbc0a9-bd7c-42a3-aa1a-3b75d497ee68` | The above plus management-plane rights you do not need to call a model. |
| Azure AI User | `53ca6127-db72-4b80-b1b0-d745d6d5456d` | Project-scoped role for the broader Foundry project experience. |

Assign at the narrowest scope that works — the Foundry account, not the resource group:

```powershell
az role assignment create `
  --assignee <objectId> `
  --role "Cognitive Services User" `
  --scope $(az cognitiveservices account show -n <account> -g <rg> --query id -o tsv)
```

`./scripts/deploy.ps1 -GrantSelfAccess` does this during deployment. Role assignments can take several minutes to propagate; a `401`/`403` immediately after deployment is usually propagation, not misconfiguration.

### Turning keys off entirely

```bicep
param disableFoundryLocalAuth = true
```

This sets `disableLocalAuth` on the Cognitive Services account. `az cognitiveservices account keys list` still returns strings, but the service rejects them. Entra becomes the only way in. Deploy with keys enabled, verify the Entra path works, *then* flip the switch — otherwise a propagation delay looks like a broken deployment.

### Verdict

**Fully supported and the recommended configuration for the direct path.** No secret is ever written to disk, tokens are short-lived and refreshed automatically by the credential chain, access is revoked by removing a role assignment, and Entra Conditional Access (MFA, device compliance, named locations, risk-based policies) applies to the sign-in that produced the token.

## Scenario B — Gateway: Claude Code → API Management → Foundry with Entra

There are two hops, and each can be secured with Entra independently.

### Hop 1 — client to gateway

The inbound policy runs `validate-azure-ad-token`:

```xml
<validate-azure-ad-token tenant-id="{{entra-tenant-id}}"
                         header-name="Authorization"
                         failed-validation-httpcode="401"
                         output-token-variable-name="callerToken">
  <audiences>
    <audience>{{entra-audience}}</audience>
  </audiences>
</validate-azure-ad-token>
```

This validates the signature, issuer and audience against the tenant's published keys **before** the request reaches a model — so an invalid token costs nothing. The validated token is captured in `callerToken`, and the policy derives `callerId` from the `oid` claim (falling back to `appid`, then the subscription ID, then the client IP) for quota and metrics.

You can additionally require claims — for example, restrict to a specific application or group:

```xml
<required-claims>
  <claim name="groups" match="any">
    <value>00000000-0000-0000-0000-000000000000</value>
  </claim>
</required-claims>
```

#### The audience caveat — read this

By default `{{entra-audience}}` is `https://ai.azure.com`, because that is the audience Claude Code's credential chain requests. That works, but the audience is a **Microsoft first-party resource**, not something you own. Anyone in the tenant who can obtain a token for it presents a structurally valid token to your gateway. The gateway's real authorization boundary is therefore the `required-claims` you add plus the API Management subscription/product model — not the audience alone.

For strict isolation, register your own application and use its audience:

```powershell
$appId = az ad app create --display-name "claude-gateway" `
  --identifier-uris "api://claude-gateway" --query appId -o tsv

# Redeploy with:
#   gatewayEntraAudience = 'api://claude-gateway'
```

Clients then supply that token explicitly, because the default credential chain will not request a custom audience on its own:

```powershell
$env:ANTHROPIC_FOUNDRY_AUTH_TOKEN = (az account get-access-token `
  --resource api://claude-gateway --query accessToken -o tsv)
```

Trade-off: you gain a real, owned authorization boundary with app roles and admin consent, and you lose the "just run `az login`" simplicity, because the static token expires in about an hour and Claude Code does not refresh it. For a demo, show the default first and describe this as the production hardening step.

### Hop 2 — gateway to Foundry

Selected by `{{backend-auth-mode}}`:

**`managedIdentity` (default)**

```xml
<authentication-managed-identity resource="{{foundry-token-resource}}"
                                 output-token-variable-name="foundryToken" />
<set-header name="Authorization" exists-action="override">
  <value>@("Bearer " + (string)context.Variables["foundryToken"])</value>
</set-header>
```

The gateway's **system-assigned managed identity** gets `Cognitive Services User` on the Foundry account (granted by `main.bicep`). No secret exists between gateway and model, and Azure rotates the identity's credentials. This is what makes `disableFoundryLocalAuth = true` viable for the gateway path.

**`passthrough`**

The caller's own validated token is forwarded untouched. Foundry evaluates RBAC against the **end user**, so per-user authorization and Foundry-side audit are preserved end to end — at the cost of every developer needing their own role assignment on the account.

Switch between them without redeploying:

```powershell
./scripts/Set-GatewayAuthMode.ps1 -BackendAuth passthrough
./scripts/Set-GatewayAuthMode.ps1 -BackendAuth managedIdentity
```

### Verdict

**Fully supported, in two distinct topologies.** Use `managedIdentity` when you want the gateway to be the trust boundary and Foundry to be reachable by exactly one identity. Use `passthrough` when Foundry-side per-user RBAC and audit are a compliance requirement.

## Choosing a topology

| You care most about | Configuration |
| --- | --- |
| Simplest possible demo | Direct + Entra credential chain (row 2) |
| No secrets anywhere | Gateway + Entra client + managed identity backend, `disableFoundryLocalAuth = true` (row 5) |
| Per-user RBAC and audit in Foundry | Gateway + Entra client + passthrough (row 6) |
| Machine-to-machine, non-Entra clients | Gateway + subscription key + managed identity (row 4) |
| Owned authorization boundary | Row 5 or 6 with a custom `api://` audience and `required-claims` |

## Layered controls worth mentioning

- **Conditional Access** applies to the interactive sign-in that produced the token — MFA, compliant device, named location, sign-in risk.
- **Private networking**: put API Management on a VNet (StandardV2/PremiumV2) and give the Foundry account a private endpoint with `publicNetworkAccess = Disabled`, so the gateway is the only network path.
- **API Management products and subscriptions** give you an approval workflow and per-product policy on top of Entra identity.
- **Managed identity for clients too**: a CI agent or App Service can call either endpoint with its own managed identity — `DefaultAzureCredential` picks it up with zero code changes.

## Verify each scenario

```powershell
# Direct + Entra
./scripts/Test-ClaudeEndpoint.ps1 -Mode Direct -Auth Entra

# Gateway + Entra, managed-identity backend
./scripts/Set-GatewayAuthMode.ps1 -ClientAuth entra -BackendAuth managedIdentity
./scripts/Test-ClaudeEndpoint.ps1 -Mode Gateway -Auth Entra

# Gateway + Entra, passthrough backend
./scripts/Set-GatewayAuthMode.ps1 -BackendAuth passthrough
./scripts/Test-ClaudeEndpoint.ps1 -Mode Gateway -Auth Entra

# Prove keys are dead when local auth is disabled (expect failure)
./scripts/Test-ClaudeEndpoint.ps1 -Mode Direct -Auth Key
```

## Inspecting a token

```powershell
$t = az account get-access-token --resource https://ai.azure.com --query accessToken -o tsv
$payload = $t.Split('.')[1].Replace('-','+').Replace('_','/')
$payload = $payload.PadRight([int][math]::Ceiling($payload.Length/4)*4, '=')
[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json |
  Select-Object aud, iss, oid, appid, tid, scp, roles
```

Check that `aud` matches `{{entra-audience}}` and `tid` matches `{{entra-tenant-id}}`. Mismatches here explain nearly every gateway `401`.

## Verified against a live deployment

Executed 2026-08-20 against a Foundry account in `eastus2` with `claude-haiku-4-5` (version `2`).

### Direct path, Entra token � confirmed working

```powershell
$tok = az account get-access-token --resource https://ai.azure.com --query accessToken -o tsv
@{ model = 'claude-haiku-4-5'; max_tokens = 100
   messages = @(@{ role = 'user'; content = 'Say hello.' }) } |
  ConvertTo-Json -Depth 5 | Set-Content "$env:TEMP\b.json" -Encoding ascii

curl.exe -s -X POST "https://<account>.services.ai.azure.com/anthropic/v1/messages" `
  -H "Authorization: Bearer $tok" `
  -H "anthropic-version: 2023-06-01" `
  -H "Content-Type: application/json" `
  -d "@$env:TEMP\b.json"
```

Returned `HTTP 200`:

```json
{ "model": "claude-haiku-4-5-20251001", "type": "message", "role": "assistant",
  "content": [ { "type": "text", "text": "..." } ],
  "usage": { "input_tokens": 24, "output_tokens": 19, "service_tier": "standard" } }
```

Three things this proves:

1. **`https://ai.azure.com` is the correct token resource.** Requesting `https://cognitiveservices.azure.com` against the `/anthropic` surface does not work; the Anthropic passthrough is a distinct audience.
2. **`Cognitive Services User` is sufficient.** No key was ever issued, and no `Contributor` was needed.
3. **The `model` field takes the deployment name** (`claude-haiku-4-5`), while the response echoes the resolved upstream build (`claude-haiku-4-5-20251001`).

Two request-shaping notes that cost real debugging time:

- Send the body from a **file** (`-d "@file"`), not an inline string. PowerShell mangles the embedded quotes of an inline JSON literal and Foundry replies `400 Request body could not be parsed as JSON` � which is easily misread as an auth problem.
- `anthropic-version: 2023-06-01` is mandatory. Omitting it is also a `400`.

### Keys were not merely unused � they were unavailable

On the tenant used for this validation, `az cognitiveservices account keys list` failed:

```
(BadRequest) Failed to list key. disableLocalAuth is set to be true
```

even though the template deployed `disableFoundryLocalAuth = false`. An Azure Policy `modify` effect had rewritten the property after ARM accepted the request, and all three key-based calls (`api-key`, `x-api-key`, and no credential) returned `401`.

This is a useful demo result rather than an obstacle: it shows the Entra path is the one that survives a hardened enterprise tenant, and it means `gatewayBackendAuthMode = 'managedIdentity'` is not just the recommended default but the only viable backend setting on such a subscription. See [07-troubleshooting.md](07-troubleshooting.md).
