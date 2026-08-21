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

// -----------------------------------------------------------------------------

var uniqueSuffix = take(uniqueString(subscription().subscriptionId, resourceGroupName), 6)
var foundryAccountName = '${workloadName}-${environmentName}-${uniqueSuffix}'
var foundryProjectName = 'proj-${workloadName}'
var apimServiceName = 'apim-${workloadName}-${environmentName}-${uniqueSuffix}'
var workspaceName = 'log-${workloadName}-${environmentName}'
var appInsightsName = 'appi-${workloadName}-${environmentName}'

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: location
  tags: tags
}

module monitoring 'modules/monitoring.bicep' = {
  name: 'monitoring'
  scope: rg
  params: {
    location: location
    tags: tags
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
    tags: tags
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
    tags: tags
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
  }
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
    tokensPerMinute: gatewayTokensPerMinute
    subscriptionKeyHeader: gatewaySubscriptionKeyHeader
    // API Management validates the subscription key in its own pipeline, *before* the
    // inbound policy executes. Leaving the built-in check on for 'either' would reject
    // Entra-only callers with SubscriptionKeyNotFound before the policy could accept
    // them, so the check is delegated to the policy for any mode that permits Entra.
    subscriptionRequired: gatewayClientAuthMode == 'subscriptionKey'
    bodyLogBytes: gatewayBodyLogBytes
  }
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
