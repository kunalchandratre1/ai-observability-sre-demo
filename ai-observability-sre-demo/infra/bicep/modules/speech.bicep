param prefix string
param env string
param location string
param aksUamiPrincipalId string
param logAnalyticsWorkspaceId string
param tags object

resource speech 'Microsoft.CognitiveServices/accounts@2024-10-01' = {
  name: '${prefix}-speech-${env}'
  location: location
  tags: tags
  kind: 'SpeechServices'
  sku: { name: 'S0' }
  identity: { type: 'SystemAssigned' }
  properties: {
    customSubDomainName: '${prefix}-speech-${env}'
    publicNetworkAccess: 'Enabled'
  }
}

var roleCogUser = 'a97b65f3-24c7-4388-baec-2e87135dc908'
resource raCogUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(speech.id, aksUamiPrincipalId, 'speech-user')
  scope: speech
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleCogUser)
    principalId: aksUamiPrincipalId
    principalType: 'ServicePrincipal'
  }
}

resource diag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-la'
  scope: speech
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [ { categoryGroup: 'allLogs', enabled: true } ]
    metrics: [ { category: 'AllMetrics', enabled: true } ]
  }
}

output speechId string = speech.id
output endpoint string = speech.properties.endpoint
output name string = speech.name
