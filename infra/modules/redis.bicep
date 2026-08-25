// =============================================================================
// Azure Managed Redis used as the API Management external cache.
//
// This exists purely to back the semantic cache. The llm-semantic-cache-lookup
// and llm-semantic-cache-store policies store prompt vectors and responses in
// whatever cache API Management is configured to use, and vector similarity
// search needs the RediSearch module - so the built-in API Management cache
// cannot serve them.
//
// Two constraints drive the shape of this file, and both are one-way doors:
//
//   1. RediSearch can only be enabled when the cache is created. There is no
//      way to add a module to an existing Azure Managed Redis instance, so
//      getting this wrong means deleting and recreating the cache.
//
//   2. API Management connects with a Redis connection string, which means
//      access key authentication must stay enabled. Microsoft Entra
//      authentication to Azure Managed Redis is not supported by API
//      Management's external cache today.
// =============================================================================

@description('Azure region for the cache.')
param location string

@description('Tags applied to every resource in this module.')
param tags object

@description('Name of the Azure Managed Redis cluster. Must be globally unique.')
param redisName string

@description('''
Azure Managed Redis SKU. Balanced_B0 is the smallest tier that supports modules
and is sufficient for a demo-scale semantic cache. Memory, not throughput, is
the binding constraint when caching prompt vectors.
''')
param skuName string = 'Balanced_B0'

resource redis 'Microsoft.Cache/redisEnterprise@2025-07-01' = {
  name: redisName
  location: location
  tags: tags
  sku: {
    name: skuName
  }
  properties: {
    // Required from API version 2025-07-01 onward. The gateway reaches the
    // cache over the public endpoint because this API Management instance is
    // not VNet-injected; a v2 tier with VNet integration would use a private
    // endpoint here instead.
    publicNetworkAccess: 'Enabled'
  }
}

resource redisDatabase 'Microsoft.Cache/redisEnterprise/databases@2025-07-01' = {
  parent: redis
  name: 'default'
  properties: {
    // API Management's external cache connects with a Redis connection string,
    // so access keys must stay on. From API version 2025-04-01 onward this
    // defaults to 'Disabled', and listKeys then fails with
    // "The ListKeys operation is not supported when access keys are disabled."
    // The SecurityControl=Ignore tag applied by main.bicep is what stops tenant
    // policy from turning it back off.
    accessKeysAuthentication: 'Enabled'
    // EnterpriseCluster presents a single logical endpoint and proxies commands
    // internally. OSSCluster, the Azure Managed Redis default, requires a
    // cluster-aware client; API Management's cache client is not, so the
    // default policy would connect but fail on any keyspace operation that
    // crosses a shard.
    clusteringPolicy: 'EnterpriseCluster'
    evictionPolicy: 'NoEviction'
    clientProtocol: 'Encrypted'
    port: 10000
    modules: [
      {
        // Vector similarity search. Enabling this at create time is the whole
        // reason this module exists rather than a plain Azure Cache for Redis.
        name: 'RediSearch'
      }
    ]
  }
}

@description('Redis cluster name.')
output redisName string = redis.name

@description('Redis resource ID, referenced by the API Management external cache entry.')
output redisId string = redis.id

@description('Hostname of the cache.')
output hostName string = redis.properties.hostName
