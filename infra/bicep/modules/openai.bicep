param prefix string
param env string
param location string
param aksUamiPrincipalId string
param logAnalyticsWorkspaceId string
param openAiSku string
param chatDeploymentName string
param tags object

resource oai 'Microsoft.CognitiveServices/accounts@2024-10-01' = {
  name: '${prefix}-openai-${env}'
  location: location
  tags: tags
  kind: 'OpenAI'
  sku: { name: openAiSku }
  identity: { type: 'SystemAssigned' }
  properties: {
    customSubDomainName: '${prefix}-openai-${env}'
    publicNetworkAccess: 'Enabled'
  }
}

resource chatDeploy 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = {
  name: chatDeploymentName
  parent: oai
  sku: { name: 'GlobalStandard', capacity: 30 }
  properties: {
    model: { format: 'OpenAI', name: 'gpt-4o-mini', version: '2024-07-18' }
  }
}

var roleCogUser = 'a97b65f3-24c7-4388-baec-2e87135dc908'
resource raCogUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(oai.id, aksUamiPrincipalId, 'openai-user')
  scope: oai
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleCogUser)
    principalId: aksUamiPrincipalId
    principalType: 'ServicePrincipal'
  }
}

resource diag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-la'
  scope: oai
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [ { categoryGroup: 'allLogs', enabled: true } ]
    metrics: [ { category: 'AllMetrics', enabled: true } ]
  }
}

output id string = oai.id
output endpoint string = oai.properties.endpoint
output chatDeployment string = chatDeploy.name
output name string = oai.name
