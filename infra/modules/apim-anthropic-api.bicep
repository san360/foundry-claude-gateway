// =============================================================================
// Anthropic Messages API surface on the AI gateway.
//
// Publishes https://<apim>.azure-api.net/<path>/v1/messages and forwards to
// https://<foundry>.services.ai.azure.com/anthropic/v1/messages, applying
// Entra validation, token-rate governance and backend identity swapping.
// =============================================================================

@description('Name of the existing API Management instance.')
param apimName string

@description('Name of the existing Application Insights logger on the APIM instance.')
param loggerName string

@description('Anthropic base URL of the Foundry account, without a trailing slash.')
param foundryAnthropicBaseUrl string

@description('Public path segment for the API. Clients call https://<apim>.azure-api.net/<apiPath>/v1/messages.')
param apiPath string = 'anthropic'

@description('Header name carrying the API Management subscription key. Claude Code sends its Foundry key as "api-key".')
param subscriptionKeyHeader string = 'api-key'

@description('Require an API Management subscription key. Set false when the gateway is protected by Entra ID only.')
param subscriptionRequired bool = true

@description('How callers authenticate to the gateway.')
@allowed([
  'subscriptionKey'
  'entra'
  'either'
])
param clientAuthMode string = 'either'

@description('How the gateway authenticates to Foundry. managedIdentity swaps the credential; passthrough forwards the caller token.')
@allowed([
  'managedIdentity'
  'passthrough'
])
param backendAuthMode string = 'managedIdentity'

@description('Entra ID tenant used to validate inbound tokens.')
param entraTenantId string = tenant().tenantId

@description('Expected audience claim on inbound Entra tokens. Claude Code and the Anthropic SDKs request https://ai.azure.com.')
param entraAudience string = 'https://ai.azure.com'

@description('''
Second accepted audience. Claude Desktop signs in with a customer-owned app
registration, and https://ai.azure.com exposes no service principal that such an
app can be granted - so it can only ever present a Cognitive Services token.
Accepting both lets the CLI and the desktop app share one gateway. This is safe
under managedIdentity backend auth, where the gateway replaces the caller token
with its own before calling Foundry; both values are still validated for issuer
and signature.
''')
param entraAudienceAdditional string = 'https://cognitiveservices.azure.com'

@description('''
Application (client) ID of the app registration backing Claude Desktop's
"Interactive sign-in" credential kind, created by
scripts/New-GatewaySsoAppRegistration.ps1. Tokens minted for this app are
accepted as an additional audience.

This is the audience that makes the gateway path work in a tenant with
restricted consent. The direct path has to request a scope on Microsoft's
Cognitive Services API, which you do not own and therefore cannot pre-authorize,
so a locked-down tenant stops every user at "Need admin approval". Here the token
is only ever presented to API Management, and the gateway calls Foundry with its
own managed identity - so the user needs no Foundry permission at all.

Leave empty to keep the scenario switched off.
''')
param gatewaySsoAppId string = ''

@description('''
Comma-separated object IDs of the Entra security groups allowed to call the
gateway with an interactive sign-in token. Leave empty to accept any
authenticated user.

Authorization is enforced here rather than by turning on "Assignment required" on
the app registration, because assignment-required applications must have their
permissions consented by an administrator - which would defeat the entire point
of this scenario. The trade-off is that an unauthorized user signs in
successfully and is refused by the gateway with 403, and that removing someone
from the group takes effect when their token next expires rather than instantly.
''')
param gatewayAllowedGroupIds string = ''

@description('Resource the gateway managed identity requests a token for when calling Foundry.')
param foundryTokenResource string = 'https://ai.azure.com'

@description('''
Serve GET /v1/models from the gateway. Foundry's Anthropic surface does not
implement the endpoint - it answers 404 api_not_supported - so Claude Desktop's
"Model discovery" toggle cannot work against Foundry directly. When enabled the
gateway synthesises the response by listing the account's model deployments over
ARM with its own managed identity, filtering to Anthropic-format deployments in
the Succeeded state, and shaping the result like Anthropic's models endpoint.
''')
param enableModelDiscovery bool = true

@description('ARM resource ID of the Foundry account, used to enumerate deployments for model discovery.')
param foundryAccountResourceId string = ''

@description('Seconds to cache the synthesised model list. Discovery runs at client launch, so a short cache removes ARM from the hot path without hiding a newly added deployment for long.')
@minValue(0)
@maxValue(3600)
param modelDiscoveryCacheSeconds int = 300

@description('Tokens per minute allowed per caller before the gateway returns 429.')
param tokensPerMinute int = 20000

@description('''
Enforce prompt guardrails at the gateway using Azure AI Content Safety.

This matters because Microsoft's platform RAI content filter does not execute
for Anthropic-format deployments - raiPolicyName is accepted on the ARM resource
but the runtime filter only intercepts the Azure OpenAI surface, so harmful
prompts reach Claude and are answered by Claude's own refusal rather than being
blocked by Azure. Enabling this makes the gateway call Content Safety
(text:shieldPrompt and text:analyze) before the model, so a blocked prompt never
reaches Claude and costs no model tokens.
''')
param enableGuardrails bool = true

@description('Azure AI Content Safety base URL, without a trailing slash. The Foundry AIServices account serves this on its own host, so no separate resource is required.')
param contentSafetyEndpoint string = ''

@description('''
Content Safety base URL in the cognitiveservices.azure.com form. The native
llm-content-safety policy validates the hostname of the backend it is pointed
at and rejects the services.ai.azure.com alias, even though both resolve to the
same AIServices account.
''')
param contentSafetyCognitiveEndpoint string = ''

@description('Enable llm-semantic-cache-lookup and llm-semantic-cache-store on the API.')
param enableSemanticCache bool = false

@description('Runtime URL of the embeddings deployment used to vectorise prompts for the semantic cache.')
param embeddingsBackendUrl string = ''

@description('Similarity threshold for a semantic cache hit. Lower is stricter.')
param semanticCacheScoreThreshold string = '0.05'

@description('Seconds a cached completion stays valid.')
param semanticCacheDurationSeconds int = 120

@description('Resource the gateway managed identity requests a token for when calling Content Safety.')
param contentSafetyTokenResource string = 'https://cognitiveservices.azure.com'

@description('''
Block the request when any Content Safety harm category scores at or above this
severity. Scores use the EightSeverityLevels scale (0-7), so 2 is permissive,
4 blocks medium and above, and 6 blocks only severe content.
''')
@minValue(1)
@maxValue(7)
param guardrailSeverityThreshold int = 4

@description('''
Azure AI Content Safety blocklist applied alongside the harm categories. The
severity classifiers score some genuinely harmful prompts 0 - first-person
self-harm intent is the measured example - so no threshold can catch them and a
blocklist is the only control that does. Empty omits the element entirely.
''')
param guardrailBlocklistName string = ''

@description('Bytes of request and response body logged to Application Insights. 0 disables body logging. Maximum 8192.')
@minValue(0)
@maxValue(8192)
param bodyLogBytes int = 8192

var backendId = 'foundry-anthropic'
var contentSafetyBackendId = 'content-safety'
var embeddingsBackendId = 'embeddings'

// Guardrails need somewhere to send the prompt; without an endpoint the policy
// branch stays off rather than failing every request.
var guardrailsActive = enableGuardrails && !empty(contentSafetyCognitiveEndpoint)

// The lookup policy needs an embeddings backend to vectorise the prompt. The
// cache itself is registered separately, by the apim-cache module.
var semanticCacheActive = enableSemanticCache && !empty(embeddingsBackendUrl)

// ARM's deployments collection for the Foundry account. Model discovery reads
// this with the gateway's managed identity, which already holds Cognitive
// Services User - that role carries Microsoft.CognitiveServices/*/read, so
// enumerating deployments needs no additional role assignment.
var foundryDeploymentsUri = empty(foundryAccountResourceId)
  ? ''
  : '${environment().resourceManager}${substring(foundryAccountResourceId, 1)}/deployments?api-version=2024-10-01'

var policyXml = replace(
  replace(
    replace(
      replace(
        replace(
          replace(
            replace(
              replace(
                replace(
                  replace(loadTextContent('../policies/anthropic-api.xml'), '__TOKENS_PER_MINUTE__', string(tokensPerMinute)),
                  '__BACKEND_ID__',
                  backendId
                ),
                '__MODEL_DISCOVERY__',
                (enableModelDiscovery && !empty(foundryAccountResourceId)) ? 'enabled' : 'disabled'
              ),
              '__DISCOVERY_CACHE_SECONDS__',
              string(modelDiscoveryCacheSeconds)
            ),
            '__GUARDRAILS__',
            guardrailsActive ? 'enabled' : 'disabled'
          ),
          '__GUARDRAIL_SEVERITY_THRESHOLD__',
          string(guardrailSeverityThreshold)
        ),
        '__CONTENT_SAFETY_BACKEND_ID__',
        contentSafetyBackendId
      ),
      '__SEMANTIC_CACHE__',
      semanticCacheActive ? 'enabled' : 'disabled'
    ),
    '__EMBEDDINGS_BACKEND_ID__',
    embeddingsBackendId
  ),
  '__CACHE_SCORE_THRESHOLD__',
  semanticCacheScoreThreshold
)

// The semantic cache policies have no "disabled" attribute and cannot sit inside
// a <choose>, so when the cache is switched off they are commented out of the
// policy document instead. The markers become empty strings when enabled and
// XML comment delimiters when not.
var policyXmlWithCache = replace(
  replace(
    replace(policyXml, '__CACHE_DURATION_SECONDS__', string(semanticCacheDurationSeconds)),
    '__CACHE_OPEN__',
    semanticCacheActive ? '' : '<!--'
  ),
  '__CACHE_CLOSE__',
  semanticCacheActive ? '' : '-->'
)

// <blocklists> is optional and must follow <categories>. Emitting nothing when
// no blocklist is configured keeps the policy document valid either way.
var guardrailBlocklistXml = (guardrailsActive && !empty(guardrailBlocklistName))
  ? '\n              <blocklists>\n                <id>${guardrailBlocklistName}</id>\n              </blocklists>'
  : ''

var policyXmlFinal = replace(policyXmlWithCache, '__GUARDRAIL_BLOCKLISTS__', guardrailBlocklistXml)

resource apim 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: apimName
}

resource logger 'Microsoft.ApiManagement/service/loggers@2024-05-01' existing = {
  parent: apim
  name: loggerName
}

// -- Named values ------------------------------------------------------------
// Kept as named values rather than baked into the policy so the demo can flip
// authentication topologies from the portal or CLI without a redeploy.

resource nvClientAuthMode 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'client-auth-mode'
  properties: {
    displayName: 'client-auth-mode'
    value: clientAuthMode
    secret: false
  }
}

resource nvBackendAuthMode 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'backend-auth-mode'
  properties: {
    displayName: 'backend-auth-mode'
    value: backendAuthMode
    secret: false
  }
}

resource nvEntraTenantId 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'entra-tenant-id'
  properties: {
    displayName: 'entra-tenant-id'
    value: entraTenantId
    secret: false
  }
}

resource nvEntraAudience 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'entra-audience'
  properties: {
    displayName: 'entra-audience'
    value: entraAudience
    secret: false
  }
}

resource nvEntraAudienceAlt 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'entra-audience-alt'
  properties: {
    displayName: 'entra-audience-alt'
    value: entraAudienceAdditional
    secret: false
  }
}

resource nvGatewaySsoAudience 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'gateway-sso-audience'
  properties: {
    displayName: 'gateway-sso-audience'
    // Sentinel rather than an empty string: an empty <audience> element makes
    // validate-azure-ad-token reject every token. A value that cannot be a real
    // audience simply never matches, so the scenario is inert until configured.
    value: empty(gatewaySsoAppId) ? 'gateway-sso-not-configured' : gatewaySsoAppId
    secret: false
  }
}

resource nvGatewaySsoAudienceAlt 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'gateway-sso-audience-alt'
  properties: {
    displayName: 'gateway-sso-audience-alt'
    value: empty(gatewaySsoAppId) ? 'api://gateway-sso-not-configured' : 'api://${gatewaySsoAppId}'
    secret: false
  }
}

resource nvGatewayAllowedGroups 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'gateway-allowed-groups'
  properties: {
    displayName: 'gateway-allowed-groups'
    // 'disabled' turns the group check off entirely, which is the right default:
    // an empty allow-list that is enforced would lock everyone out.
    value: empty(gatewayAllowedGroupIds) ? 'disabled' : gatewayAllowedGroupIds
    secret: false
  }
}

resource nvFoundryTokenResource 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'foundry-token-resource'
  properties: {
    displayName: 'foundry-token-resource'
    value: foundryTokenResource
    secret: false
  }
}

// Always created, even when discovery is off, so the policy's {{...}} reference
// always resolves. An unresolved named value fails the whole policy at apply
// time, not just the branch that uses it.
resource nvFoundryDeploymentsUri 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'foundry-deployments-uri'
  properties: {
    displayName: 'foundry-deployments-uri'
    value: empty(foundryDeploymentsUri) ? environment().resourceManager : foundryDeploymentsUri
    secret: false
  }
}

// Always created, even when guardrails are off, so the policy's {{...}}
// references always resolve. An unresolved named value fails the whole policy
// at apply time, not just the branch that uses it.
resource nvContentSafetyEndpoint 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'content-safety-endpoint'
  properties: {
    displayName: 'content-safety-endpoint'
    value: empty(contentSafetyEndpoint) ? 'https://contentsafety.invalid' : contentSafetyEndpoint
    secret: false
  }
}

resource nvContentSafetyTokenResource 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'content-safety-token-resource'
  properties: {
    displayName: 'content-safety-token-resource'
    value: contentSafetyTokenResource
    secret: false
  }
}

// -- Backend -----------------------------------------------------------------

resource foundryBackend 'Microsoft.ApiManagement/service/backends@2024-05-01' = {
  parent: apim
  name: backendId
  properties: {
    title: 'Microsoft Foundry - Anthropic Messages API'
    description: 'Claude models deployed in Microsoft Foundry.'
    protocol: 'http'
    url: foundryAnthropicBaseUrl
  }
}

// The native llm-content-safety policy resolves its Content Safety target
// through a backend entity rather than a URL, and insists on two things: the
// hostname must be the cognitiveservices.azure.com form, and the credentials
// must be a managed identity with an exact resource of
// https://cognitiveservices.azure.com. A trailing slash on that resource value
// is rejected.
resource contentSafetyBackend 'Microsoft.ApiManagement/service/backends@2024-05-01' = if (guardrailsActive) {
  parent: apim
  name: contentSafetyBackendId
  properties: {
    title: 'Azure AI Content Safety'
    description: 'Content Safety data plane on the Foundry AIServices account, used by the native llm-content-safety policy.'
    protocol: 'http'
    url: contentSafetyCognitiveEndpoint
    credentials: {
      #disable-next-line BCP037
      managedIdentity: {
        resource: 'https://cognitiveservices.azure.com'
      }
    }
  }
}

// Vectoriser for the semantic cache. llm-semantic-cache-lookup posts the
// extracted prompt here and compares the returned embedding against stored
// vectors, so this points at the embeddings deployment rather than a Claude one.
resource embeddingsBackend 'Microsoft.ApiManagement/service/backends@2024-05-01' = if (semanticCacheActive) {
  parent: apim
  name: embeddingsBackendId
  properties: {
    title: 'Foundry embeddings'
    description: 'Embeddings deployment used by llm-semantic-cache-lookup to vectorise prompts.'
    protocol: 'http'
    url: embeddingsBackendUrl
    credentials: {
      #disable-next-line BCP037
      managedIdentity: {
        resource: 'https://cognitiveservices.azure.com'
      }
    }
  }
}

// -- API ---------------------------------------------------------------------

resource anthropicApi 'Microsoft.ApiManagement/service/apis@2024-05-01' = {
  parent: apim
  name: 'anthropic'
  properties: {
    displayName: 'Claude on Microsoft Foundry (Anthropic Messages API)'
    description: 'Anthropic Messages API passthrough to Claude models deployed in Microsoft Foundry.'
    path: apiPath
    protocols: [
      'https'
    ]
    apiType: 'http'
    subscriptionRequired: subscriptionRequired
    subscriptionKeyParameterNames: {
      header: subscriptionKeyHeader
      query: 'subscription-key'
    }
    serviceUrl: foundryAnthropicBaseUrl
  }
}

resource opCreateMessage 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: anthropicApi
  name: 'messages-create'
  properties: {
    displayName: 'Create a message'
    method: 'POST'
    urlTemplate: '/v1/messages'
    description: 'Anthropic Messages API. Set "model" to a Foundry deployment name.'
  }
}

resource opCountTokens 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: anthropicApi
  name: 'messages-count-tokens'
  properties: {
    displayName: 'Count message tokens'
    method: 'POST'
    urlTemplate: '/v1/messages/count_tokens'
  }
}

resource opListModels 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: anthropicApi
  name: 'models-list'
  properties: {
    displayName: 'List models'
    method: 'GET'
    urlTemplate: '/v1/models'
  }
}

// Catch-all operations keep the API usable when Anthropic adds endpoints that
// this template does not model explicitly.
resource opCatchAllPost 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: anthropicApi
  name: 'catch-all-post'
  properties: {
    displayName: 'Passthrough (POST)'
    method: 'POST'
    urlTemplate: '/*'
  }
}

resource opCatchAllGet 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: anthropicApi
  name: 'catch-all-get'
  properties: {
    displayName: 'Passthrough (GET)'
    method: 'GET'
    urlTemplate: '/*'
  }
}

resource apiPolicy 'Microsoft.ApiManagement/service/apis/policies@2024-05-01' = {
  parent: anthropicApi
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: policyXmlFinal
  }
  dependsOn: [
    nvClientAuthMode
    nvBackendAuthMode
    nvEntraTenantId
    nvEntraAudience
    nvEntraAudienceAlt
    nvFoundryTokenResource
    nvFoundryDeploymentsUri
    nvContentSafetyEndpoint
    nvContentSafetyTokenResource
    foundryBackend
    contentSafetyBackend
    embeddingsBackend
    opCreateMessage
    opCountTokens
    opListModels
    opCatchAllPost
    opCatchAllGet
  ]
}

resource apiDiagnostic 'Microsoft.ApiManagement/service/apis/diagnostics@2024-05-01' = {
  parent: anthropicApi
  name: 'applicationinsights'
  properties: {
    loggerId: logger.id
    alwaysLog: 'allErrors'
    httpCorrelationProtocol: 'W3C'
    verbosity: 'information'
    // Without this, llm-emit-token-metric runs and silently emits nothing.
    // Azure Monitor custom metrics are opt-in per diagnostic entity, and the
    // portal does not surface the toggle. Note the counts land in the Azure
    // Monitor metrics store under the policy's namespace, not in the
    // AppMetrics Log Analytics table.
    metrics: true
    sampling: {
      samplingType: 'fixed'
      percentage: 100
    }
    // Body logging makes it possible to show the actual Claude Code system
    // prompt and tool definitions traversing the gateway. Prompts routinely
    // contain source code, so reduce or disable this outside a demo.
    frontend: {
      request: {
        body: {
          bytes: bodyLogBytes
        }
      }
      response: {
        body: {
          bytes: bodyLogBytes
        }
      }
    }
    backend: {
      request: {
        body: {
          bytes: bodyLogBytes
        }
      }
      response: {
        body: {
          bytes: bodyLogBytes
        }
      }
    }
  }
}

// -- Product and demo subscription -------------------------------------------

resource product 'Microsoft.ApiManagement/service/products@2024-05-01' = {
  parent: apim
  name: 'claude-code'
  properties: {
    displayName: 'Claude Code'
    description: 'Access to Claude models in Microsoft Foundry through the AI gateway.'
    subscriptionRequired: true
    approvalRequired: false
    state: 'published'
    subscriptionsLimit: 100
  }
}

resource productApi 'Microsoft.ApiManagement/service/products/apis@2024-05-01' = {
  parent: product
  name: anthropicApi.name
}

resource demoSubscription 'Microsoft.ApiManagement/service/subscriptions@2024-05-01' = {
  parent: apim
  name: 'claude-code-demo'
  properties: {
    displayName: 'Claude Code demo'
    scope: product.id
    state: 'active'
    allowTracing: true
  }
  dependsOn: [
    productApi
  ]
}

@description('Base URL to set as ANTHROPIC_FOUNDRY_BASE_URL when routing Claude Code through the gateway.')
output gatewayAnthropicBaseUrl string = '${apim.properties.gatewayUrl}/${apiPath}'

@description('Resource ID of the demo subscription. Use listSecrets to read the key.')
output demoSubscriptionId string = demoSubscription.id

@description('Name of the demo subscription.')
output demoSubscriptionName string = demoSubscription.name

@description('Header name that carries the API Management subscription key.')
output subscriptionKeyHeader string = subscriptionKeyHeader

@description('Whether the gateway enforces Azure AI Content Safety guardrails on inbound prompts.')
output guardrailsEnabled bool = guardrailsActive

@description('Severity at or above which a harm category blocks the request (EightSeverityLevels, 0-7).')
output guardrailSeverityThreshold int = guardrailSeverityThreshold

@description('Content Safety blocklist enforced by the policy, or empty when none is configured.')
output guardrailBlocklistName string = (guardrailsActive && !empty(guardrailBlocklistName)) ? guardrailBlocklistName : ''
