param prefix string
param env string
param location string
param logAnalyticsWorkspaceId string
param tags object

resource redis 'Microsoft.Cache/Redis@2024-03-01' = {
  name: '${prefix}-redis-${env}-${uniqueString(resourceGroup().id)}'
  location: location
  tags: tags
  properties: {
    sku: { name: 'Basic', family: 'C', capacity: 0 }
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
    metrics: [ { category: 'AllMetrics', enabled: true } ]
  }
}

output redisId string = redis.id
output hostName string = redis.properties.hostName
output redisName string = redis.name
