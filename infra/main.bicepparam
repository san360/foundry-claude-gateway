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
//
// ALWAYS check availability, version AND quota in your region first:
//   az cognitiveservices model list --location eastus2 \
//     --query "[?model.format=='Anthropic'].{name:model.name, version:model.version}" -o table
//   az cognitiveservices usage list --location eastus2 \
//     --query "[?contains(name.value,'laude')].{name:name.value, limit:limit}" -o table
//
// Version '2' = Hosted on Azure (inference stays in Azure), shown in the quota
// list with an ".Azure" suffix. Version '1' = Hosted on Anthropic. Not every
// model offers both, and a model with limit 0 cannot be deployed at all.
// -----------------------------------------------------------------------------
param haikuModel = 'claude-haiku-4-5'
param sonnetModel = 'claude-sonnet-4-6'
param opusModel = ''

param haikuCapacity = 10
param sonnetCapacity = 25

// Verified in eastus2: haiku-4-5 offers version 2 (Hosted on Azure), while
// sonnet-4-6 is only published as version 1.
param haikuModelVersion = '2'
param sonnetModelVersion = '1'
param opusModelVersion = '2'

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
