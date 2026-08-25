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

// Tenant policy forces disableLocalAuth=true on Cognitive Services accounts
// unless the resource carries SecurityControl=Ignore. Keep this true to make
// the key-based scenarios deployable; it must be present at CREATE time, since
// adding the tag afterwards does not re-open keys on an already-hardened
// account. Never set this on a production workload.
param allowLocalAuthExemption = true

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

// Header carrying the API Management subscription key. 'x-api-key' is
// Anthropic's own convention, is what the Foundry Anthropic endpoint itself
// expects, and is one of only two schemes Claude Desktop can send. Using it
// everywhere means one header name across both scenarios.
param gatewaySubscriptionKeyHeader = 'x-api-key'

// Bytes of request/response body logged to Application Insights. Great for a
// demo ("here is the actual system prompt"), but prompts routinely contain
// source code — set to 0 for anything resembling production.
param gatewayBodyLogBytes = 8192

// Enforce Azure AI Content Safety on inbound prompts at the gateway. This is
// what makes guardrails demonstrable: Azure's platform RAI filter does not run
// for Anthropic-format deployments, so the direct path relies entirely on
// Claude's own refusals while the gateway path blocks before the model is
// called. Run scripts/Test-Guardrails.ps1 to see the contrast.
param gatewayGuardrails = true

// Harm severity that trips a block, on the 0-7 EightSeverityLevels scale.
// 4 blocks medium and above, which is the closest analogue to the Azure OpenAI
// default content filter.
param gatewayGuardrailSeverityThreshold = 4

// Semantic cache. Answers a repeated - or merely reworded - prompt from Redis
// instead of the model, for zero model tokens. This is the only part of the
// stack that needs its own resource, and Azure Managed Redis bills hourly, so
// set it to false for a long-lived idle demo environment.
param gatewaySemanticCache = true

// Azure Managed Redis capacity is allocated per region PER SKU, and a busy
// region rejects the create with AllocationFailed after several minutes. We hit
// exactly that on eastus2 at both Balanced_B0 and Balanced_B1, while eastus took
// the same SKU immediately - so the cache lives next door. The APIM external
// cache is registered with useFromLocation 'default', so cross-region is
// supported; it costs a few milliseconds on a hit. Leave as '' to co-locate.
param redisLocation = 'eastus'

// Attach a strict custom RAI policy to the Claude deployments. Deployed as
// reproducible evidence rather than as a working control: ARM accepts and
// reports the binding, but nothing enforces it on the Anthropic surface.
param deployStrictRaiPolicy = true
