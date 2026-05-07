param prefix string
param env string
param location string
param aksUamiPrincipalId string
param apimUamiPrincipalId string
param tags object

var nsName = '${prefix}-ehns-${env}-${uniqueString(resourceGroup().id)}'

resource ns 'Microsoft.EventHub/namespaces@2024-01-01' = {
  name: nsName
  location: location
  tags: tags
  sku: { name: 'Standard', tier: 'Standard', capacity: 2 }
  properties: {
    isAutoInflateEnabled: true
    maximumThroughputUnits: 10
    kafkaEnabled: true
  }
}

resource hubAks 'Microsoft.EventHub/namespaces/eventhubs@2024-01-01' = {
  name: 'aks-otel'
  parent: ns
  properties: {
    partitionCount: 4
    messageRetentionInDays: 1
  }
}

resource hubApim 'Microsoft.EventHub/namespaces/eventhubs@2024-01-01' = {
  name: 'apim-diag'
  parent: ns
  properties: {
    partitionCount: 4
    messageRetentionInDays: 1
  }
}

// Consumer groups for ADX ingestion
resource cgAdxAks 'Microsoft.EventHub/namespaces/eventhubs/consumergroups@2024-01-01' = {
  name: 'adx'
  parent: hubAks
}
resource cgAdxApim 'Microsoft.EventHub/namespaces/eventhubs/consumergroups@2024-01-01' = {
  name: 'adx'
  parent: hubApim
}

var roleEhSender = '2b629674-e913-4c01-ae53-ef4638d8f975'

resource raAksToHub 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(hubAks.id, aksUamiPrincipalId, 'sender')
  scope: hubAks
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleEhSender)
    principalId: aksUamiPrincipalId
    principalType: 'ServicePrincipal'
  }
}

resource raApimToHub 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(hubApim.id, apimUamiPrincipalId, 'sender')
  scope: hubApim
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleEhSender)
    principalId: apimUamiPrincipalId
    principalType: 'ServicePrincipal'
  }
}

output namespaceId string = ns.id
output namespaceName string = ns.name
output namespaceFqdn string = '${ns.name}.servicebus.windows.net'
output aksOtelHubId string = hubAks.id
output aksOtelHubName string = hubAks.name
output apimDiagHubId string = hubApim.id
output apimDiagHubName string = hubApim.name
