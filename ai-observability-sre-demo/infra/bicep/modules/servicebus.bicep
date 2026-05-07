param prefix string
param env string
param location string
param aksUamiPrincipalId string
param logAnalyticsWorkspaceId string
param tags object

var nsName = '${prefix}-sb-${env}-${uniqueString(resourceGroup().id)}'

resource ns 'Microsoft.ServiceBus/namespaces@2024-01-01' = {
  name: nsName
  location: location
  tags: tags
  sku: { name: 'Standard', tier: 'Standard' }
}

resource queue 'Microsoft.ServiceBus/namespaces/queues@2024-01-01' = {
  name: 'voice-orders'
  parent: ns
  properties: {
    maxDeliveryCount: 5
    lockDuration: 'PT1M'
    enablePartitioning: false
  }
}

var roleSender = '69a216fc-b8fb-44d8-bc22-1f3c2cd27a39'
var roleReceiver = '4f6d3b9b-027b-4f4c-9142-0e5a2a2247e0'

resource raSender 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(queue.id, aksUamiPrincipalId, 'sb-sender')
  scope: queue
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleSender)
    principalId: aksUamiPrincipalId
    principalType: 'ServicePrincipal'
  }
}

resource raReceiver 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(queue.id, aksUamiPrincipalId, 'sb-receiver')
  scope: queue
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleReceiver)
    principalId: aksUamiPrincipalId
    principalType: 'ServicePrincipal'
  }
}

resource diag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-la'
  scope: ns
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [ { categoryGroup: 'allLogs', enabled: true } ]
    metrics: [ { category: 'AllMetrics', enabled: true } ]
  }
}

output namespaceId string = ns.id
output namespaceName string = ns.name
output namespaceFqdn string = '${ns.name}.servicebus.windows.net'
output queueName string = queue.name
