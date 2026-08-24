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

@description('Bytes of request and response body logged to Application Insights. 0 disables body logging. Maximum 8192.')
@minValue(0)
@maxValue(8192)
param bodyLogBytes int = 8192

var backendId = 'foundry-anthropic'

// Guardrails need somewhere to send the prompt; without an endpoint the policy
// branch stays off rather than failing every request.
var guardrailsActive = enableGuardrails && !empty(contentSafetyEndpoint)

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
)

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
    value: policyXml
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
