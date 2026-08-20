using 'main.bicep'

// -----------------------------------------------------------------------------
// Required: describe the organization that will use Claude. These values are
// sent to Anthropic as model-provider attestation with every request.
// -----------------------------------------------------------------------------
param claudeOrganizationName = 'Contoso'
param claudeCountryCode = 'US'
param claudeIndustry = 'technology'

// -----------------------------------------------------------------------------
// Naming and placement
// -----------------------------------------------------------------------------
param workloadName = 'claudedemo'
param environmentName = 'demo'
param location = 'eastus2'

// -----------------------------------------------------------------------------
// Claude deployments. Deployment names become the values you set as
// ANTHROPIC_DEFAULT_*_MODEL for Claude Code. Set a family to '' to skip it.
// Check availability in your region before changing these.
// -----------------------------------------------------------------------------
param haikuModel = 'claude-haiku-4-5'
param sonnetModel = 'claude-sonnet-4-6'
param opusModel = ''

param haikuCapacity = 10
param sonnetCapacity = 25

// '2' = Hosted on Azure (inference stays in Azure). '1' = Hosted on Anthropic.
param modelVersion = '2'

// -----------------------------------------------------------------------------
// Access. Set principalId to your own object ID so you can call the model with
// Microsoft Entra ID immediately after deployment:
//   az ad signed-in-user show --query id -o tsv
// -----------------------------------------------------------------------------
param principalId = ''
param principalType = 'User'

// Flip to true to prove the Entra-only story: Foundry then rejects API keys.
param disableFoundryLocalAuth = false

// -----------------------------------------------------------------------------
// AI gateway (Azure API Management). Set deployGateway = false to demo the
// direct path only and avoid the API Management cost.
// -----------------------------------------------------------------------------
param deployGateway = true
param apimSkuName = 'BasicV2'
param apimSkuCapacity = 1
param apimPublisherEmail = 'admin@contoso.com'
param apimPublisherName = 'Contoso'

// 'either'         accept an APIM subscription key or an Entra token
// 'entra'          require an Entra token (no subscription key)
// 'subscriptionKey' require an APIM subscription key only
param gatewayClientAuthMode = 'either'

// 'managedIdentity' gateway swaps the client credential for its own MI token
// 'passthrough'     caller's Entra token is forwarded to Foundry unchanged
param gatewayBackendAuthMode = 'managedIdentity'

param gatewayEntraAudience = 'https://ai.azure.com'
param foundryTokenResource = 'https://ai.azure.com'
param gatewayTokensPerMinute = 20000
param gatewaySubscriptionKeyHeader = 'api-key'

// Bytes of request/response body logged to Application Insights. Great for a
// demo ("here is the actual system prompt"), but prompts routinely contain
// source code — set to 0 for anything resembling production.
param gatewayBodyLogBytes = 8192
