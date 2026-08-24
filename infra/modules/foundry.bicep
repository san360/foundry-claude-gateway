// =============================================================================
// Microsoft Foundry account + project + Anthropic Claude model deployments.
//
// Exposes the Anthropic Messages API at:
//   https://<account>.services.ai.azure.com/anthropic/v1/messages
//
// Each model family (Haiku / Sonnet / Opus) is independent. Pass an empty
// string to skip a family. Deployments are chained because Foundry serializes
// deployment creation under a single account and concurrent creates return 409.
// =============================================================================

@description('Azure region for the Foundry account.')
param location string

@description('Tags applied to every resource in this module.')
param tags object

@description('Name of the Foundry (Cognitive Services / AIServices) account.')
param accountName string

@description('Name of the Foundry project created under the account.')
param projectName string

@description('Claude Haiku model ID, for example claude-haiku-4-5. Empty string skips this family.')
param haikuModel string = ''

@description('Claude Sonnet model ID, for example claude-sonnet-4-6. Empty string skips this family.')
param sonnetModel string = ''

@description('Claude Opus model ID, for example claude-opus-4-8. Empty string skips this family.')
param opusModel string = ''

@description('Capacity in thousands of tokens per minute for the Haiku deployment.')
param haikuCapacity int = 10

@description('Capacity in thousands of tokens per minute for the Sonnet deployment.')
param sonnetCapacity int = 25

@description('Capacity in thousands of tokens per minute for the Opus deployment.')
param opusCapacity int = 25

@description('Model version for the Haiku deployment. Version 2 is "Hosted on Azure"; version 1 is "Hosted on Anthropic". Availability differs per model.')
param haikuModelVersion string = '2'

@description('Model version for the Sonnet deployment. Version 2 is "Hosted on Azure"; version 1 is "Hosted on Anthropic". Availability differs per model.')
param sonnetModelVersion string = '2'

@description('Model version for the Opus deployment. Version 2 is "Hosted on Azure"; version 1 is "Hosted on Anthropic". Availability differs per model.')
param opusModelVersion string = '2'

// -- Anthropic model-provider attestation ------------------------------------
// These values are sent to Anthropic with every request. They must describe the
// real organization using the model.

@description('Legal entity name of the organization using Claude.')
param claudeOrganizationName string

@description('Two-letter country code of the organization using Claude.')
param claudeCountryCode string

@description('Industry of the organization using Claude. Must be lowercase.')
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
param claudeIndustry string

// -- Access control ----------------------------------------------------------

@description('Object ID of the interactive user or service principal to grant inference access. Empty string skips the assignment.')
param principalId string = ''

@description('Principal type for the principalId role assignment.')
@allowed([
  'User'
  'ServicePrincipal'
  'Group'
])
param principalType string = 'User'

@description('Additional principal object IDs (for example the API Management managed identity) to grant inference access.')
param additionalInferencePrincipalIds array = []

@description('Disable API key authentication so the account only accepts Microsoft Entra ID tokens.')
param disableLocalAuth bool = false

// Built-in "Cognitive Services User" role. Least-privilege role for calling a
// deployed model: grants Microsoft.CognitiveServices/accounts/MaaS/* only.
var cognitiveServicesUserRoleId = 'a97b65f3-24c7-4388-baec-2e87135dc908'

var haikuDeploymentName = empty(haikuModel) ? '' : haikuModel
var sonnetDeploymentName = empty(sonnetModel) ? '' : sonnetModel
var opusDeploymentName = empty(opusModel) ? '' : opusModel

resource account 'Microsoft.CognitiveServices/accounts@2025-10-01-preview' = {
  name: accountName
  location: location
  tags: tags
  kind: 'AIServices'
  sku: {
    name: 'S0'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    customSubDomainName: accountName
    allowProjectManagement: true
    publicNetworkAccess: 'Enabled'
    disableLocalAuth: disableLocalAuth
  }
}

resource project 'Microsoft.CognitiveServices/accounts/projects@2025-10-01-preview' = {
  parent: account
  name: projectName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {}
}

// Role assignments are declared before the model deployments so the model
// deployment wait doubles as RBAC propagation time.
resource userInferenceAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(principalId)) {
  name: guid(account.id, principalId, cognitiveServicesUserRoleId)
  scope: account
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', cognitiveServicesUserRoleId)
    principalId: principalId
    principalType: principalType
  }
}

resource additionalInferenceAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for pid in additionalInferencePrincipalIds: {
    name: guid(account.id, pid, cognitiveServicesUserRoleId)
    scope: account
    properties: {
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', cognitiveServicesUserRoleId)
      principalId: pid
      principalType: 'ServicePrincipal'
    }
  }
]

@description('''
Deploy a deliberately strict custom RAI (content filter) policy and attach it to
the Claude deployments.

This exists as evidence, not as a working control. Azure accepts the policy and
binds it to Anthropic-format deployments, but the runtime filter pipeline only
intercepts the Azure OpenAI inference surface - not /anthropic/v1/messages. With
every category blocking at the lowest severity threshold, a mass-casualty
violence prompt still returns HTTP 200 and is answered by Claude's own refusal.
Deploying it lets the demo prove that claim rather than assert it, and means the
posture is already correct if Microsoft enables enforcement later. Real
enforcement is done by the AI gateway - see docs/08-guardrails.md.
''')
param deployStrictRaiPolicy bool = true

var strictRaiPolicyName = 'claude-strict'

// Every harm category, blocking, on both prompt and completion, at the lowest
// severity threshold the service accepts - the strictest policy expressible.
var harmFilters = flatten(map(['Hate', 'Sexual', 'Violence', 'Selfharm'], category =>
  map(['Prompt', 'Completion'], source => {
    name: category
    blocking: true
    enabled: true
    severityThreshold: 'Low'
    source: source
  })))

resource strictRaiPolicy 'Microsoft.CognitiveServices/accounts/raiPolicies@2024-10-01' = if (deployStrictRaiPolicy) {
  parent: account
  name: strictRaiPolicyName
  properties: {
    mode: 'Blocking'
    basePolicyName: 'Microsoft.DefaultV2'
    contentFilters: concat(harmFilters, [
      {
        name: 'Jailbreak'
        blocking: true
        enabled: true
        source: 'Prompt'
      }
      {
        name: 'Protected Material Text'
        blocking: true
        enabled: true
        source: 'Completion'
      }
    ])
  }
}

var effectiveRaiPolicyName = deployStrictRaiPolicy ? strictRaiPolicyName : 'Microsoft.DefaultV2'

resource haikuDeployment 'Microsoft.CognitiveServices/accounts/deployments@2025-10-01-preview' = if (!empty(haikuModel)) {
  parent: account
  name: haikuDeploymentName
  sku: {
    name: 'GlobalStandard'
    capacity: haikuCapacity
  }
  properties: {
    model: {
      format: 'Anthropic'
      name: haikuModel
      version: haikuModelVersion
    }
    raiPolicyName: effectiveRaiPolicyName
    #disable-next-line BCP037
    modelProviderData: {
      organizationName: claudeOrganizationName
      countryCode: claudeCountryCode
      industry: claudeIndustry
    }
  }
  dependsOn: [
    project
    userInferenceAccess
    additionalInferenceAccess
    strictRaiPolicy
  ]
}

resource sonnetDeployment 'Microsoft.CognitiveServices/accounts/deployments@2025-10-01-preview' = if (!empty(sonnetModel)) {
  parent: account
  name: sonnetDeploymentName
  sku: {
    name: 'GlobalStandard'
    capacity: sonnetCapacity
  }
  properties: {
    model: {
      format: 'Anthropic'
      name: sonnetModel
      version: sonnetModelVersion
    }
    raiPolicyName: effectiveRaiPolicyName
    #disable-next-line BCP037
    modelProviderData: {
      organizationName: claudeOrganizationName
      countryCode: claudeCountryCode
      industry: claudeIndustry
    }
  }
  dependsOn: [
    project
    haikuDeployment
    userInferenceAccess
    additionalInferenceAccess
    strictRaiPolicy
  ]
}

resource opusDeployment 'Microsoft.CognitiveServices/accounts/deployments@2025-10-01-preview' = if (!empty(opusModel)) {
  parent: account
  name: opusDeploymentName
  sku: {
    name: 'GlobalStandard'
    capacity: opusCapacity
  }
  properties: {
    model: {
      format: 'Anthropic'
      name: opusModel
      version: opusModelVersion
    }
    raiPolicyName: effectiveRaiPolicyName
    #disable-next-line BCP037
    modelProviderData: {
      organizationName: claudeOrganizationName
      countryCode: claudeCountryCode
      industry: claudeIndustry
    }
  }
  dependsOn: [
    project
    sonnetDeployment
    userInferenceAccess
    additionalInferenceAccess
    strictRaiPolicy
  ]
}

@description('Foundry account name, used as ANTHROPIC_FOUNDRY_RESOURCE.')
output accountName string = account.name

@description('Foundry account resource ID.')
output accountId string = account.id

@description('Anthropic Messages API base URL. Append /v1/messages to call the model.')
output anthropicBaseUrl string = 'https://${account.name}.services.ai.azure.com/anthropic'

@description('Foundry project endpoint.')
output projectEndpoint string = 'https://${account.name}.services.ai.azure.com/api/projects/${project.name}'

@description('''
Azure AI Content Safety base URL. The AIServices account serves the Content
Safety data plane on the same host as the Anthropic surface, so the AI gateway
can enforce prompt guardrails without a separate resource. Callers need the
Cognitive Services User role, whose Microsoft.CognitiveServices/* data action
already covers it.
''')
output contentSafetyEndpoint string = 'https://${account.name}.services.ai.azure.com'

@description('RAI content filter policy attached to the Claude deployments. Attached and reported by ARM, but not enforced on the Anthropic surface - see docs/08-guardrails.md.')
output raiPolicyName string = effectiveRaiPolicyName

output haikuDeploymentName string = haikuDeploymentName
output sonnetDeploymentName string = sonnetDeploymentName
output opusDeploymentName string = opusDeploymentName
