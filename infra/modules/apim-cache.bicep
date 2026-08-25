// =============================================================================
// Registers Azure Managed Redis as the API Management external cache.
//
// The connection string is built here rather than passed in. A @secure() module
// output can only be read through a direct module reference (BCP426), and the
// conditional module that creates Redis can only be dereferenced with the
// null-forgiving operator - which does not qualify. Resolving the key from an
// existing resource sidesteps the restriction and keeps the secret out of both
// module outputs and the deployment history.
// =============================================================================

@description('Name of the existing API Management instance.')
param apimName string

@description('Name of the Azure Managed Redis cluster to register as the external cache.')
param redisName string

resource apim 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: apimName
}

resource redis 'Microsoft.Cache/redisEnterprise@2025-07-01' existing = {
  name: redisName

  resource database 'databases' existing = {
    name: 'default'
  }
}

// Named 'default' so every gateway location uses it. A cache registered for a
// specific region would take precedence over this entry.
//
// abortConnect=False keeps the gateway serving requests when the cache is
// briefly unreachable rather than failing the connection outright - a cache
// miss should degrade latency, never availability.
resource externalCache 'Microsoft.ApiManagement/service/caches@2024-05-01' = {
  parent: apim
  name: 'default'
  properties: {
    description: 'Azure Managed Redis with RediSearch, backing the LLM semantic cache.'
    connectionString: '${redis.properties.hostName}:10000,password=${redis::database.listKeys().primaryKey},ssl=True,abortConnect=False'
    useFromLocation: 'default'
  }
}

@description('Name of the external cache entry.')
output cacheName string = externalCache.name
