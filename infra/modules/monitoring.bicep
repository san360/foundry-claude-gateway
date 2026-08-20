// =============================================================================
// Log Analytics workspace + Application Insights used for AI gateway telemetry.
// The llm-emit-token-metric policy writes prompt/completion/total token counts
// here as custom metrics.
// =============================================================================

@description('Azure region for the monitoring resources.')
param location string

@description('Tags applied to every resource in this module.')
param tags object

@description('Name of the Log Analytics workspace.')
param workspaceName string

@description('Name of the Application Insights component.')
param appInsightsName string

@description('Data retention in days.')
param retentionInDays int = 30

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: workspaceName
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: retentionInDays
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: workspace.id
    IngestionMode: 'LogAnalytics'
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

output workspaceId string = workspace.id
output workspaceName string = workspace.name
output appInsightsId string = appInsights.id
output appInsightsName string = appInsights.name

@description('Instrumentation key consumed by the API Management Application Insights logger.')
#disable-next-line outputs-should-not-contain-secrets
output appInsightsInstrumentationKey string = appInsights.properties.InstrumentationKey
