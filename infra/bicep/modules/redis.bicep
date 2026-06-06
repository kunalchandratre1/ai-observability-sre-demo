param prefix string
param env string
param location string
param redisSku string
param logAnalyticsWorkspaceId string
param tags object

var redisFamily = redisSku == 'Premium' ? 'P' : 'C'
var redisCapacity = redisSku == 'Premium' ? 1 : 0

resource redis 'Microsoft.Cache/Redis@2024-03-01' = {
  name: '${prefix}-redis-${env}-${uniqueString(resourceGroup().id)}'
  location: location
  tags: tags
  properties: {
    sku: { name: redisSku, family: redisFamily, capacity: redisCapacity }
    enableNonSslPort: false
    minimumTlsVersion: '1.2'
    publicNetworkAccess: 'Enabled'
  }
}

resource diag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-la'
  scope: redis
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [ { category: 'ConnectedClientList', enabled: true } ]
    metrics: [ { category: 'AllMetrics', enabled: true } ]
  }
}

output redisId string = redis.id
output hostName string = redis.properties.hostName
output redisName string = redis.name
