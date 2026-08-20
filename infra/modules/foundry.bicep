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

@description('Model version to deploy. Version 2 is "Hosted on Azure"; version 1 is "Hosted on Anthropic".')
param modelVersion string = '2'

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
      version: modelVersion
    }
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
      version: modelVersion
    }
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
      version: modelVersion
    }
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

output haikuDeploymentName string = haikuDeploymentName
output sonnetDeploymentName string = sonnetDeploymentName
output opusDeploymentName string = opusDeploymentName
