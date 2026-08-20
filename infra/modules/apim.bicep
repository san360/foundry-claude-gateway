// =============================================================================
// Azure API Management instance used as the AI gateway.
//
// Deployed separately from the Anthropic API configuration so the ordering is:
//   1. this module           -> creates APIM, emits its managed identity
//   2. foundry module        -> grants that identity Cognitive Services User
//   3. apim-anthropic-api    -> wires the backend + policy to Foundry
//
// A v2 tier is required: the AI gateway support for the Anthropic Messages API
// schema (llm-token-limit, llm-emit-token-metric) is only available on v2.
// =============================================================================

@description('Azure region for the API Management instance.')
param location string

@description('Tags applied to every resource in this module.')
param tags object

@description('Name of the API Management instance. Must be globally unique.')
param apimName string

@description('API Management SKU. Must be a v2 tier for Anthropic Messages API support.')
@allowed([
  'BasicV2'
  'StandardV2'
  'PremiumV2'
])
param skuName string = 'BasicV2'

@description('Number of scale units.')
param skuCapacity int = 1

@description('Publisher email shown on the developer portal and used for notifications.')
param publisherEmail string

@description('Publisher organization name.')
param publisherName string

@description('Resource ID of the Application Insights component used for AI gateway telemetry.')
param appInsightsId string

@description('Instrumentation key of the Application Insights component.')
@secure()
param appInsightsInstrumentationKey string

@description('Resource ID of the Log Analytics workspace to send gateway diagnostics to.')
param logAnalyticsWorkspaceId string

resource apim 'Microsoft.ApiManagement/service@2024-05-01' = {
  name: apimName
  location: location
  tags: tags
  sku: {
    name: skuName
    capacity: skuCapacity
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    publisherEmail: publisherEmail
    publisherName: publisherName
  }
}

resource apimLogger 'Microsoft.ApiManagement/service/loggers@2024-05-01' = {
  parent: apim
  name: 'appinsights'
  properties: {
    loggerType: 'applicationInsights'
    description: 'Application Insights logger for AI gateway token metrics.'
    resourceId: appInsightsId
    credentials: {
      instrumentationKey: appInsightsInstrumentationKey
    }
    isBuffered: true
  }
}

resource apimDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'apim-to-log-analytics'
  scope: apim
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

@description('API Management instance name.')
output apimName string = apim.name

@description('API Management resource ID.')
output apimId string = apim.id

@description('Public gateway URL, for example https://my-apim.azure-api.net.')
output gatewayUrl string = apim.properties.gatewayUrl

@description('Object ID of the API Management system-assigned managed identity.')
output principalId string = apim.identity.principalId

@description('Name of the Application Insights logger, referenced by API diagnostics.')
output loggerName string = apimLogger.name
