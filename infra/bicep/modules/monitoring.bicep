param prefix string
param env string
param location string
param logAnalyticsSku string
param tags object

resource la 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: '${prefix}-la-${env}'
  location: location
  tags: tags
  properties: {
    sku: { name: logAnalyticsSku }
    retentionInDays: 30
    features: { enableLogAccessUsingOnlyResourcePermissions: true }
  }
}

resource amw 'Microsoft.Monitor/accounts@2023-04-03' = {
  name: '${prefix}-amw-${env}'
  location: location
  tags: tags
  properties: {}
}

// Data collection rule for Managed Prometheus -> AMW
resource dceProm 'Microsoft.Insights/dataCollectionEndpoints@2022-06-01' = {
  name: '${prefix}-dce-prom-${env}'
  location: location
  tags: tags
  kind: 'Linux'
  properties: {}
}

resource dcrProm 'Microsoft.Insights/dataCollectionRules@2022-06-01' = {
  name: '${prefix}-dcr-prom-${env}'
  location: location
  tags: tags
  kind: 'Linux'
  properties: {
    dataCollectionEndpointId: dceProm.id
    dataSources: {
      prometheusForwarder: [ { name: 'PrometheusDataSource', streams: [ 'Microsoft-PrometheusMetrics' ] } ]
    }
    destinations: {
      monitoringAccounts: [ { accountResourceId: amw.id, name: 'MonitoringAccount1' } ]
    }
    dataFlows: [ {
      streams: [ 'Microsoft-PrometheusMetrics' ]
      destinations: [ 'MonitoringAccount1' ]
    } ]
  }
}

output logAnalyticsWorkspaceId string = la.id
output logAnalyticsWorkspaceName string = la.name
output monitorWorkspaceId string = amw.id
output monitorWorkspaceName string = amw.name
output dcrPromId string = dcrProm.id
output dcePromId string = dceProm.id
