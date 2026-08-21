# 05 — Microsoft Entra ID authentication

> **Short answer to "can we use Entra for both scenarios?" — Yes, for both, and in the gateway case in two different topologies. Neither path requires an API key at any point. You can deploy this template with `disableFoundryLocalAuth = true` and have no usable key anywhere in the system.**
>
> **Key-based access is supported too**, as a deliberate second credential scenario rather than a fallback of last resort. It matters because a hardened tenant may refuse consent for the app registration that Claude *Desktop* needs, and because some machine callers cannot hold a managed identity. Both credentials are demonstrated side by side; see [03](03-claude-code-direct.md) and [04](04-claude-code-gateway.md).

## The matrix

| # | Path | Client credential | Gateway → Foundry credential | Foundry sees | Supported |
| --- | --- | --- | --- | --- | --- |
| 1 | Direct | Foundry API key | — | shared key | ✓ needs `SecurityControl=Ignore` |
| 2 | **Direct** | **Entra token (`DefaultAzureCredential`)** | — | **the end user** | **✓ recommended** |
| 3 | Direct | Entra token (`ANTHROPIC_FOUNDRY_AUTH_TOKEN`) | — | the end user / SPN | ✓ |
| 4 | Gateway | APIM subscription key | gateway managed identity | the gateway | ✓ |
| 5 | **Gateway** | **Entra token, validated at the edge** | **gateway managed identity** | **the gateway** | **✓ recommended** |
| 6 | Gateway | Entra token, validated at the edge | same token passed through | **the end user** | ✓ |
| 7 | Gateway | APIM subscription key | passthrough | *(no bearer token)* | ✗ invalid combination |

Rows 2, 5 and 6 are entirely key-free. Row 4 is the best of the key-based options: the client holds a per-consumer, individually revocable gateway key and never sees a Foundry credential.

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

## The app registration — delegated access to Foundry

**Who needs one.** Claude *Desktop* only. Claude Code authenticates as a Microsoft first-party client through `az login`, so it needs no registration and no consent — which is exactly why `Test-ClaudeEndpoint.ps1 -Auth Entra` can pass on a tenant where the desktop app is still stuck at a consent prompt. If you only ever demo the CLI, you can skip this section entirely.

### Delegated, not application

Two permission types exist and only one is right here:

| | Delegated | Application |
| --- | --- | --- |
| Token represents | the signed-in user | the app itself |
| Needs a user present | yes | no |
| Client secret | none — public client + PKCE | required |
| Foundry sees | the user's object ID | a service principal |
| Right for Claude Desktop | **yes** | no |

Claude Desktop is an interactive desktop client with no server side, so there is nowhere to keep a client secret. It registers as a **public client** and uses PKCE. That also means the registration itself is not a credential — it is only an identifier, so its client ID is safe to put in a config file or check into `.env.example`.

**The delegated permission does not grant access.** It grants the app the right to *ask* for a token on the user's behalf. Whether that token can actually call a model is decided separately by Azure RBAC on the Foundry account. Two locks, both of which must be open — see [the second lock](#the-second-lock-rbac) below. This trips people up: consent succeeds, sign-in succeeds, and the first message still returns `401`.

### The exact configuration

| Property | Value | Why |
| --- | --- | --- |
| Resource application | `7d312290-28c8-473c-a0ed-8e53749b6d6d` | Azure Cognitive Services. Tenant-independent — the same GUID everywhere |
| Delegated scope | `user_impersonation`, id `5f1e8914-a52b-429f-9324-91b92b81adaf` | The only scope the resource exposes; type `Scope`, not `Role` |
| `isFallbackPublicClient` | `true` | Required for device-code, and for any flow with no client secret |
| `signInAudience` | `AzureADMyOrg` | This tenant only. Widen deliberately, never by accident |
| Redirect URI — browser | `http://127.0.0.1/callback` | Entra wildcards the loopback **port** but not the **path**. A bare `http://127.0.0.1` fails `AADSTS50011` |
| Redirect URI — broker (Windows) | `ms-appx-web://Microsoft.AAD.BrokerPlugin/{clientId}` | Contains the app's own client ID |
| Redirect URI — broker (macOS) | `msauth.com.anthropic.claudefordesktop://auth` | Anthropic's bundle identifier |
| Client secret | **none** | A secret on a public client is a finding, not a feature |

Registering all three redirect URIs costs nothing and lets you switch `inferenceFoundryAuthFlow` later without going back to Entra.

### Creating it

```powershell
./scripts/New-FoundryAppRegistration.ps1 -GrantAdminConsent
```

Idempotent — it converges the same application object by display name rather than creating duplicates, so re-running it is safe. It prints the client ID, the tenant ID and the admin-consent URL.

### Creating it by hand

If policy requires the registration be made by someone else, this is the portal equivalent. **Entra admin centre → App registrations → New registration:**

1. Name it, set **Supported account types** to *Accounts in this organizational directory only*, and register with no redirect URI.
2. **Authentication → Add a platform → Mobile and desktop applications.** Add all three URIs from the table above. Set **Allow public client flows** to *Yes*.
3. **API permissions → Add a permission → APIs my organization uses.** Search `Azure Cognitive Services` — if the name does not resolve, paste the GUID `7d312290-28c8-473c-a0ed-8e53749b6d6d`, which is stable across tenants. Choose **Delegated permissions** and tick `user_impersonation`.
4. **Grant admin consent** — see below.
5. Copy the **Application (client) ID** from *Overview*. That is what goes in `inferenceFoundryClientId`. It is **not** the directory (tenant) ID; confusing the two is the most common cause of `AADSTS700016`.

The equivalent Microsoft Graph body, which is what the script PATCHes in a single call:

```jsonc
{
  "isFallbackPublicClient": true,
  "publicClient": {
    "redirectUris": [
      "http://127.0.0.1/callback",
      "ms-appx-web://Microsoft.AAD.BrokerPlugin/{clientId}",
      "msauth.com.anthropic.claudefordesktop://auth"
    ]
  },
  "requiredResourceAccess": [
    {
      "resourceAppId": "7d312290-28c8-473c-a0ed-8e53749b6d6d",
      "resourceAccess": [
        { "id": "5f1e8914-a52b-429f-9324-91b92b81adaf", "type": "Scope" }
      ]
    }
  ]
}
```

`requiredResourceAccess` only *declares* what the app will ask for. Nothing is granted until someone consents.

### Consent — the part that actually blocks people

`user_impersonation` is classified as user-consentable, and most documentation stops there. Whether an ordinary user can actually approve it depends on the tenant's **user consent settings**, and there are three states, not two:

| Tenant setting | Effect on this app |
| --- | --- |
| *Allow user consent for apps* | The user consents at first sign-in. Nothing else to do. |
| *Allow user consent for apps from verified publishers, for selected permissions* | The user can consent **only** to permissions an admin has classified as low impact. `user_impersonation` on Cognitive Services is **not** in the default classification set, so sign-in fails. |
| *Do not allow user consent* | Every delegated permission needs an admin grant. Sign-in fails. |

The middle row is the one that catches people out, and it is the **default** in a modern tenant — the policy is named `ManagePermissionGrantsForSelf.microsoft-user-default-low`. User consent is not switched off; it is restricted to a small set of low-impact permissions, which out of the box is only Microsoft Graph `User.Read`, `openid`, `profile`, `email` and `offline_access`. Everything else, including this scope, is refused. It is easy to read the setting as "user consent is enabled" and conclude the app should work.

Check which policy your tenant uses:

```powershell
az rest --method GET `
  --url "https://graph.microsoft.com/v1.0/policies/authorizationPolicy" `
  --query "permissionGrantPolicyIdsAssignedToDefaultUserRole"
```

`ManagePermissionGrantsForSelf.microsoft-user-default-low` is the restricted default; an empty array means user consent is off entirely. Either way the symptom is the same, and terminal:

> **Need admin approval** — *Claude Desktop - Microsoft Foundry needs permission to access resources in your organisation that only an admin can grant.*

There are three ways out.

**1. Admin consent — one action, tenant-wide.** The usual answer:

```powershell
./scripts/New-FoundryAppRegistration.ps1 -GrantAdminConsent   # needs Privileged Role Admin or Global Admin
az ad app permission admin-consent --id <client-id>
```

or send an administrator this URL, which needs no tooling and no access to this repo:

```
https://login.microsoftonline.com/<tenant-id>/adminconsent?client_id=<client-id>
```

**2. Classify the permission as low impact.** Less well known, and a better fit where a security team objects to blanket admin consent but is comfortable with the scope itself. An admin adds `user_impersonation` on Cognitive Services to the low-impact set, after which **users consent for themselves** as normal, per user, and each grant stays visible and individually revocable:

```powershell
# Cognitive Services resource app: cb5ea8b8-3faa-4e4f-8c66-83f1e6b7b6ef
az rest --method POST `
  --url "https://graph.microsoft.com/v1.0/policies/permissionGrantPolicies/microsoft-user-default-low/includes" `
  --body '{
    "permissionType": "delegated",
    "resourceApplication": "cb5ea8b8-3faa-4e4f-8c66-83f1e6b7b6ef",
    "permissionClassification": "low",
    "permissions": ["user_impersonation"]
  }'
```

This still needs a directory admin, but it is a narrower and more reviewable change than granting the whole app tenant-wide.

**3. Use keys.** No registration, no consent, no directory admin — see the [key-based scenario](03-claude-code-direct.md#key-based-access-no-entra-app-required).

Check whether consent has already been granted:

```powershell
az ad app permission list-grants --id <client-id> -o table
```

An empty result means no consent exists yet, and no amount of retrying the sign-in will change that.

### The second lock: RBAC

Consent lets the user obtain a token. **Cognitive Services User** on the Foundry account is what lets that token call a model:

```powershell
./scripts/deploy.ps1 -GrantSelfAccess          # grants it to you
az role assignment create `
  --assignee <user-or-group-object-id> `
  --role "Cognitive Services User" `
  --scope <foundry-account-resource-id>        # grant the demo audience separately
```

Assign it to a **group**, not to individuals, if more than one person will use the demo. Role assignments can take a minute or two to propagate; a `401` immediately after granting one is usually just that.

### Verifying the registration

```powershell
$appId = '<client-id>'
az ad app show --id $appId --query "{
  publicClient: isFallbackPublicClient,
  audience:     signInAudience,
  redirects:    publicClient.redirectUris,
  permissions:  requiredResourceAccess
}" -o json
```

Expect `publicClient: true`, all three redirect URIs, and one `requiredResourceAccess` entry carrying the two GUIDs from the table. If `permissions` is empty, step 3 above did not save.

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

### Keys were blocked by policy, and how the block was lifted

On the tenant used for this validation, `az cognitiveservices account keys list` initially failed:

```
(BadRequest) Failed to list key. disableLocalAuth is set to be true
```

even though the template deployed `disableFoundryLocalAuth = false`. An Azure Policy `modify` effect had rewritten the property after ARM accepted the request, and every key-based call returned `401`.

**The exemption tag lifts it.** Tagging the account `SecurityControl=Ignore` takes it out of the policy's scope, and `disableLocalAuth` stays at the value the template asked for. The template applies the tag by default:

```bicep
param allowLocalAuthExemption = true   // SecurityControl=Ignore on every resource
param disableFoundryLocalAuth = false
```

Redeploying an account that the policy had already hardened flipped `disableLocalAuth` from `true` back to `false`, and `keys list` then returned a working key. Confirmed on this deployment.

Two lessons worth keeping:

1. **The policy overrides the template silently.** ARM reports `Succeeded` with the value you asked for while the live resource holds the opposite. Always verify the resource, not the deployment:

   ```powershell
   az cognitiveservices account show -n <account> -g <rg> `
     --query "{localAuth:properties.disableLocalAuth, tags:tags}"
   ```

2. **The Anthropic surface wants `x-api-key`.** With local auth enabled, `x-api-key` returns `200` while `api-key` and `Ocp-Apim-Subscription-Key` return `401` with a message about an invalid subscription key — misleading, because the key is fine and the header is not. The Azure OpenAI surface of the same account is the opposite way round, which is where the confusion comes from.

None of this changes the recommendation. Entra remains the right default: it carries a user identity into the sign-in logs, is revocable per user, and needs no secret on the client. The key path exists because a hardened tenant may block user consent for the app registration entirely (see the *Need admin approval* entry in [07-troubleshooting.md](07-troubleshooting.md)), and because `gatewayBackendAuthMode = 'managedIdentity'` keeps the *backend* keyless regardless of how the client authenticated.

