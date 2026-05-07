param prefix string
param env string
param location string
param monitorWorkspaceId string
param adxClusterUri string
param tags object

resource grafana 'Microsoft.Dashboard/grafana@2023-09-01' = {
  name: '${prefix}-grafana-${env}'
  location: location
  tags: tags
  sku: { name: 'Standard' }
  identity: { type: 'SystemAssigned' }
  properties: {
    apiKey: 'Enabled'
    publicNetworkAccess: 'Enabled'
    grafanaIntegrations: {
      azureMonitorWorkspaceIntegrations: [ { azureMonitorWorkspaceResourceId: monitorWorkspaceId } ]
    }
  }
}

// Grant Grafana SAMI Monitoring Reader at RG so it can pull Azure Monitor metrics/logs.
var roleMonReader = '43d0d8ad-25c7-4714-9337-8ba259a9fe05'
resource raGrafanaMonReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(grafana.id, 'mon-reader', resourceGroup().id)
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleMonReader)
    principalId: grafana.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

output grafanaId string = grafana.id
output endpoint string = grafana.properties.endpoint
output principalId string = grafana.identity.principalId
output adxClusterUriOut string = adxClusterUri
