// =============================================================================
// Claude on Microsoft Foundry — direct and AI-gateway demo environment.
//
//   Claude Code ──┬─ direct ──────────────────────────────► Foundry (Anthropic
//                 │                                          Messages API)
//                 └─ via Azure API Management AI gateway ───►
//
// Deploy with:
//   az deployment sub create -l <region> -f infra/main.bicep -p infra/main.bicepparam
// =============================================================================

targetScope = 'subscription'

@description('Short name used to derive resource names. Lowercase letters and numbers only.')
@minLength(3)
@maxLength(12)
param workloadName string = 'claudedemo'

@description('Environment suffix used in resource names, for example dev or demo.')
@minLength(2)
@maxLength(8)
param environmentName string = 'demo'

@description('Azure region for all resources. Must offer the selected Claude models.')
param location string = 'eastus2'

@description('Name of the resource group to create.')
param resourceGroupName string = 'rg-${workloadName}-${environmentName}'

@description('Tags applied to every resource.')
param tags object = {
  workload: workloadName
  environment: environmentName
  solution: 'claude-foundry-ai-gateway'
}

@description('Tag every resource, and the resource group itself, with SecurityControl=Ignore. This is the tenant policy exemption tag that permits local (API key) authentication. Two resources need it: the Foundry account, where policy otherwise forces disableLocalAuth=true and the key-based scenarios cannot be demonstrated, and Azure Managed Redis, where API Management\'s external cache can only connect with an access key. Never set this on a production workload.')
param allowLocalAuthExemption bool = true

// -- Claude model selection ---------------------------------------------------

@description('Claude Haiku model ID for fast background operations. Empty string skips it.')
param haikuModel string = 'claude-haiku-4-5'

@description('Claude Sonnet model ID used as the primary coding model. Empty string skips it.')
param sonnetModel string = 'claude-sonnet-4-6'

@description('Claude Opus model ID for complex reasoning. Empty string skips it.')
param opusModel string = ''

@description('Capacity in thousands of tokens per minute for the Haiku deployment.')
param haikuCapacity int = 10

@description('Capacity in thousands of tokens per minute for the Sonnet deployment.')
param sonnetCapacity int = 25

@description('Capacity in thousands of tokens per minute for the Opus deployment.')
param opusCapacity int = 25

@description('Model version for the Haiku deployment. "2" is Hosted on Azure, "1" is Hosted on Anthropic infrastructure. Availability differs per model — check with: az cognitiveservices model list --location <region> --query "[?model.format==\'Anthropic\']"')
param haikuModelVersion string = '2'

@description('Model version for the Sonnet deployment. "2" is Hosted on Azure, "1" is Hosted on Anthropic infrastructure.')
param sonnetModelVersion string = '2'

@description('Model version for the Opus deployment. "2" is Hosted on Azure, "1" is Hosted on Anthropic infrastructure.')
param opusModelVersion string = '2'

// -- Anthropic model-provider attestation -------------------------------------

@description('Legal entity name of the organization using Claude. Sent to Anthropic with every request.')
param claudeOrganizationName string

@description('Two-letter country code of the organization using Claude.')
param claudeCountryCode string = 'US'

@description('Industry of the organization using Claude.')
@allowed([
  'technology'
  'finance'
  'healthcare'
  'education'
  'retail'
  'manufacturing'
  'government'
  'media'
  'other'
])
param claudeIndustry string = 'technology'

// -- Identity and access ------------------------------------------------------

@description('Object ID of the user or service principal that will run Claude Code. Granted Cognitive Services User on the Foundry account.')
param principalId string = ''

@description('Type of the principalId.')
@allowed([
  'User'
  'ServicePrincipal'
  'Group'
])
param principalType string = 'User'

@description('Disable Foundry API keys so the account only accepts Microsoft Entra ID tokens. Recommended once the Entra path is verified.')
param disableFoundryLocalAuth bool = false

// -- AI gateway ---------------------------------------------------------------

@description('Deploy the Azure API Management AI gateway. Set false to demonstrate the direct path only.')
param deployGateway bool = true

@description('API Management SKU. A v2 tier is required for Anthropic Messages API support.')
@allowed([
  'BasicV2'
  'StandardV2'
  'PremiumV2'
])
param apimSkuName string = 'BasicV2'

@description('Number of API Management scale units.')
param apimSkuCapacity int = 1

@description('Publisher email for the API Management instance.')
param apimPublisherEmail string = 'admin@contoso.com'

@description('Publisher organization name for the API Management instance.')
param apimPublisherName string = 'Contoso'

@description('How callers authenticate to the gateway.')
@allowed([
  'subscriptionKey'
  'entra'
  'either'
])
param gatewayClientAuthMode string = 'either'

@description('How the gateway authenticates to Foundry.')
@allowed([
  'managedIdentity'
  'passthrough'
])
param gatewayBackendAuthMode string = 'managedIdentity'

@description('Expected audience on inbound Entra tokens at the gateway.')
param gatewayEntraAudience string = 'https://ai.azure.com'

@description('Second accepted audience at the gateway. Claude Desktop signs in with a customer-owned app registration, which can only obtain a Cognitive Services token; accepting both lets the CLI and the desktop app share one gateway.')
param gatewayEntraAudienceAdditional string = 'https://cognitiveservices.azure.com'

@description('Resource the gateway managed identity requests a token for when calling Foundry.')
param foundryTokenResource string = 'https://ai.azure.com'

@description('Tokens per minute allowed per caller at the gateway before it returns 429.')
param gatewayTokensPerMinute int = 20000

@description('Header name carrying the API Management subscription key.')
param gatewaySubscriptionKeyHeader string = 'api-key'

@description('Bytes of request and response body the gateway logs to Application Insights. 0 disables body logging. Reduce this outside a demo: prompts routinely contain source code.')
@minValue(0)
@maxValue(8192)
param gatewayBodyLogBytes int = 8192

@description('''
Serve GET /v1/models from the gateway so Claude Desktop's "Model discovery"
toggle works. Foundry's Anthropic surface returns 404 api_not_supported for that
path, so discovery is only possible through the gateway. The gateway lists the
account's deployments over ARM with its managed identity and returns the
Anthropic-format ones. Direct-to-Foundry clients must keep discovery off and
enumerate models explicitly.
''')
param gatewayModelDiscovery bool = true

@description('Seconds the gateway caches the synthesised model list.')
@minValue(0)
@maxValue(3600)
param gatewayModelDiscoveryCacheSeconds int = 300

@description('''
Enforce prompt guardrails at the gateway with Azure AI Content Safety.

Azure's platform RAI content filter does not run for Anthropic-format
deployments, so a harmful prompt sent straight to Foundry reaches Claude and is
answered by Claude's own refusal rather than blocked by the platform. With this
on, the gateway calls Content Safety (prompt shields plus harm-category scoring)
before the model, so blocked prompts never reach Claude and consume no model
tokens. This is the difference the gateway scenario demonstrates.
''')
param gatewayGuardrails bool = true

@description('''
Block a request when any Content Safety harm category scores at or above this
severity, on the EightSeverityLevels scale (0-7). 2 is permissive, 4 blocks
medium and above, 6 blocks only severe content.
''')
@minValue(1)
@maxValue(7)
param gatewayGuardrailSeverityThreshold int = 4

@description('''
Deploy a strict custom RAI policy and attach it to the Claude deployments. Kept
as reproducible evidence: Azure accepts and reports the binding, but does not
enforce it on the Anthropic surface. See docs/08-guardrails.md.
''')
param deployStrictRaiPolicy bool = true

@description('''
Enable semantic caching on the gateway. Deploys an Azure Managed Redis cache
with the RediSearch module, registers it as the API Management external cache,
and turns on the llm-semantic-cache-lookup and llm-semantic-cache-store
policies. This is the only feature in the stack that adds a standing hourly
cost, so it can be switched off for a cheaper demo.
''')
param gatewaySemanticCache bool = true

@description('''
Similarity score threshold for a semantic cache hit, between 0 and 1. This is a
distance, not a confidence: LOWER is stricter. 0.05 means a stored prompt must
be very close in meaning before its response is reused. Raise it to serve more
from cache, at the risk of answering a question the caller did not ask.
''')
param gatewaySemanticCacheScoreThreshold string = '0.05'

@description('Seconds a cached completion stays valid.')
param gatewaySemanticCacheDurationSeconds int = 120

@description('Azure Managed Redis SKU backing the semantic cache.')
param redisSkuName string = 'Balanced_B0'

@description('''
Region for the semantic cache. Defaults to the deployment region. Managed Redis
capacity is allocated per region per SKU and a busy region returns
AllocationFailed at create time, so this is a deliberate escape hatch: point the
cache at a neighbouring region rather than moving the whole stack. The external
cache is registered with useFromLocation "default", so cross-region works — it
just adds a few milliseconds to a cache hit.
''')
param redisLocation string = ''

// -----------------------------------------------------------------------------

var uniqueSuffix = take(uniqueString(subscription().subscriptionId, resourceGroupName), 6)
var foundryAccountName = '${workloadName}-${environmentName}-${uniqueSuffix}'
var foundryProjectName = 'proj-${workloadName}'
var apimServiceName = 'apim-${workloadName}-${environmentName}-${uniqueSuffix}'
var workspaceName = 'log-${workloadName}-${environmentName}'
var appInsightsName = 'appi-${workloadName}-${environmentName}'
var redisCacheName = 'redis-${workloadName}-${environmentName}-${uniqueSuffix}'

// The policy that forces disableLocalAuth=true evaluates the tag, so it has to
// be present at create time. Adding it later does not retroactively re-enable
// keys on an account the policy already hardened.
var allTags = union(tags, allowLocalAuthExemption ? { SecurityControl: 'Ignore' } : {})

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: location
  tags: allTags
}

module monitoring 'modules/monitoring.bicep' = {
  name: 'monitoring'
  scope: rg
  params: {
    location: location
    tags: allTags
    workspaceName: workspaceName
    appInsightsName: appInsightsName
  }
}

// Step 1: create the gateway so its managed identity exists before Foundry
// grants it inference access.
module apim 'modules/apim.bicep' = if (deployGateway) {
  name: 'apim'
  scope: rg
  params: {
    location: location
    tags: allTags
    apimName: apimServiceName
    skuName: apimSkuName
    skuCapacity: apimSkuCapacity
    publisherEmail: apimPublisherEmail
    publisherName: apimPublisherName
    appInsightsId: monitoring.outputs.appInsightsId
    appInsightsInstrumentationKey: monitoring.outputs.appInsightsInstrumentationKey
    logAnalyticsWorkspaceId: monitoring.outputs.workspaceId
  }
}

// Step 2: Foundry account, project, Claude deployments and RBAC. The gateway
// identity is granted Cognitive Services User here so it can mint tokens for
// the Anthropic endpoint.
module foundry 'modules/foundry.bicep' = {
  name: 'foundry'
  scope: rg
  params: {
    location: location
    tags: allTags
    accountName: foundryAccountName
    projectName: foundryProjectName
    haikuModel: haikuModel
    sonnetModel: sonnetModel
    opusModel: opusModel
    haikuCapacity: haikuCapacity
    sonnetCapacity: sonnetCapacity
    opusCapacity: opusCapacity
    haikuModelVersion: haikuModelVersion
    sonnetModelVersion: sonnetModelVersion
    opusModelVersion: opusModelVersion
    claudeOrganizationName: claudeOrganizationName
    claudeCountryCode: claudeCountryCode
    claudeIndustry: claudeIndustry
    principalId: principalId
    principalType: principalType
    additionalInferencePrincipalIds: deployGateway ? [apim!.outputs.principalId] : []
    disableLocalAuth: disableFoundryLocalAuth
    deployStrictRaiPolicy: deployStrictRaiPolicy
  }
}

// Step 2b: Redis for the gateway semantic cache. Independent of Foundry, so it
// deploys in parallel with it; only the gateway API module needs both.
module redis 'modules/redis.bicep' = if (deployGateway && gatewaySemanticCache) {
  name: 'redis'
  scope: rg
  params: {
    location: empty(redisLocation) ? location : redisLocation
    tags: allTags
    redisName: redisCacheName
    skuName: redisSkuName
  }
}

// Registers Redis as the gateway's external cache. Separate module because the
// connection string is a secure output and must be referenced directly.
module apimCache 'modules/apim-cache.bicep' = if (deployGateway && gatewaySemanticCache) {
  name: 'apim-external-cache'
  scope: rg
  params: {
    apimName: apimServiceName
    redisName: redisCacheName
  }
  dependsOn: [
    apim
    redis
  ]
}

// Step 3: publish the Anthropic Messages API on the gateway, pointing at the
// Foundry account created above.
module gatewayApi 'modules/apim-anthropic-api.bicep' = if (deployGateway) {
  name: 'gateway-anthropic-api'
  scope: rg
  params: {
    apimName: apimServiceName
    loggerName: apim!.outputs.loggerName
    foundryAnthropicBaseUrl: foundry.outputs.anthropicBaseUrl
    clientAuthMode: gatewayClientAuthMode
    backendAuthMode: gatewayBackendAuthMode
    entraAudience: gatewayEntraAudience
    entraAudienceAdditional: gatewayEntraAudienceAdditional
    foundryTokenResource: foundryTokenResource
    enableModelDiscovery: gatewayModelDiscovery
    foundryAccountResourceId: foundry.outputs.accountId
    modelDiscoveryCacheSeconds: gatewayModelDiscoveryCacheSeconds
    tokensPerMinute: gatewayTokensPerMinute
    subscriptionKeyHeader: gatewaySubscriptionKeyHeader
    // API Management validates the subscription key in its own pipeline, *before* the
    // inbound policy executes. Leaving the built-in check on for 'either' would reject
    // Entra-only callers with SubscriptionKeyNotFound before the policy could accept
    // them, so the check is delegated to the policy for any mode that permits Entra.
    subscriptionRequired: gatewayClientAuthMode == 'subscriptionKey'
    bodyLogBytes: gatewayBodyLogBytes
    enableGuardrails: gatewayGuardrails
    // The AIServices account serves Content Safety on its own host, so the
    // gateway needs no separate resource - and its managed identity already
    // holds Cognitive Services User, which covers the data plane.
    contentSafetyEndpoint: foundry.outputs.contentSafetyEndpoint
    // The native llm-content-safety policy validates the backend hostname and
    // only accepts the cognitiveservices.azure.com form of the same account.
    contentSafetyCognitiveEndpoint: foundry.outputs.contentSafetyCognitiveEndpoint
    guardrailSeverityThreshold: gatewayGuardrailSeverityThreshold
    enableSemanticCache: gatewaySemanticCache
    embeddingsBackendUrl: foundry.outputs.embeddingsBackendUrl
    semanticCacheScoreThreshold: gatewaySemanticCacheScoreThreshold
    semanticCacheDurationSeconds: gatewaySemanticCacheDurationSeconds
  }
  dependsOn: [
    apimCache
  ]
}

// -- Outputs ------------------------------------------------------------------

@description('Resource group containing the deployment.')
output resourceGroupName string = rg.name

@description('Foundry resource name. Set as ANTHROPIC_FOUNDRY_RESOURCE for the direct path.')
output foundryAccountName string = foundry.outputs.accountName

@description('Direct Anthropic base URL. Set as ANTHROPIC_FOUNDRY_BASE_URL for the direct path.')
output foundryAnthropicBaseUrl string = foundry.outputs.anthropicBaseUrl

@description('Foundry project endpoint.')
output foundryProjectEndpoint string = foundry.outputs.projectEndpoint

@description('Whether API key (local) authentication was requested on the Foundry account. Tenant policy can still override this; scripts verify the live value rather than trusting it.')
output foundryLocalAuthEnabled bool = !disableFoundryLocalAuth

@description('Whether the SecurityControl=Ignore policy exemption tag was applied.')
output localAuthExemptionTagApplied bool = allowLocalAuthExemption

@description('Gateway Anthropic base URL. Set as ANTHROPIC_FOUNDRY_BASE_URL for the gateway path.')
output gatewayAnthropicBaseUrl string = deployGateway ? gatewayApi!.outputs.gatewayAnthropicBaseUrl : ''

@description('API Management instance name.')
output apimName string = deployGateway ? apim!.outputs.apimName : ''

@description('Name of the pre-created API Management subscription used by the demo.')
output gatewaySubscriptionName string = deployGateway ? gatewayApi!.outputs.demoSubscriptionName : ''

@description('Header that carries the API Management subscription key.')
output gatewaySubscriptionKeyHeader string = deployGateway ? gatewayApi!.outputs.subscriptionKeyHeader : ''

@description('Audiences the gateway accepts on inbound Entra tokens. Clients must request a token for one of these.')
output gatewayEntraAudiences array = deployGateway ? [gatewayEntraAudience, gatewayEntraAudienceAdditional] : []

@description('Deployment name to set as ANTHROPIC_DEFAULT_HAIKU_MODEL.')
output haikuDeploymentName string = foundry.outputs.haikuDeploymentName

@description('Deployment name to set as ANTHROPIC_DEFAULT_SONNET_MODEL.')
output sonnetDeploymentName string = foundry.outputs.sonnetDeploymentName

@description('Deployment name to set as ANTHROPIC_DEFAULT_OPUS_MODEL.')
output opusDeploymentName string = foundry.outputs.opusDeploymentName

@description('Application Insights component used for gateway token metrics.')
output appInsightsName string = monitoring.outputs.appInsightsName

@description('Azure AI Content Safety endpoint. Served by the Foundry account itself, and used by the gateway to enforce prompt guardrails.')
output contentSafetyEndpoint string = foundry.outputs.contentSafetyEndpoint

@description('RAI policy attached to the Claude deployments. Reported by ARM but NOT enforced on the Anthropic surface - the gateway is the enforcement point. See docs/08-guardrails.md.')
output raiPolicyName string = foundry.outputs.raiPolicyName

@description('Whether the gateway enforces Azure AI Content Safety guardrails on inbound prompts.')
output gatewayGuardrailsEnabled bool = deployGateway ? gatewayApi!.outputs.guardrailsEnabled : false

@description('Harm severity (0-7) at or above which the gateway blocks a prompt.')
output gatewayGuardrailSeverityThreshold int = deployGateway ? gatewayApi!.outputs.guardrailSeverityThreshold : 0

@description('Whether the gateway semantic cache is deployed and wired into the policy.')
output gatewaySemanticCacheEnabled bool = deployGateway && gatewaySemanticCache

@description('Embeddings deployment vectorising prompts for the semantic cache.')
output embeddingDeploymentName string = foundry.outputs.embeddingDeploymentName

@description('Azure Managed Redis cache backing the semantic cache.')
output redisCacheName string = (deployGateway && gatewaySemanticCache) ? redis!.outputs.redisName : ''

@description('Per-caller token ceiling enforced by llm-token-limit, per minute.')
output gatewayTokensPerMinute int = deployGateway ? gatewayTokensPerMinute : 0
