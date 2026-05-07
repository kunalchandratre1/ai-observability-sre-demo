param prefix string
param env string
param location string
param privateEndpointSubnetId string
param privateDnsZoneIdCosmos string
param aksUamiPrincipalId string
param logAnalyticsWorkspaceId string
param tags object

var accountName = take('${prefix}cosmos${env}${uniqueString(resourceGroup().id)}', 44)

resource cosmos 'Microsoft.DocumentDB/databaseAccounts@2024-05-15' = {
  name: accountName
  location: location
  tags: tags
  kind: 'GlobalDocumentDB'
  properties: {
    databaseAccountOfferType: 'Standard'
    consistencyPolicy: { defaultConsistencyLevel: 'Session' }
    locations: [ { locationName: location, failoverPriority: 0 } ]
    publicNetworkAccess: 'Disabled'
    enableAutomaticFailover: false
    capabilities: []
  }
}

resource db 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases@2024-05-15' = {
  name: 'orders'
  parent: cosmos
  properties: {
    resource: { id: 'orders' }
    options: { throughput: 400 }
  }
}

resource container 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers@2024-05-15' = {
  name: 'voice-orders'
  parent: db
  properties: {
    resource: {
      id: 'voice-orders'
      partitionKey: { paths: [ '/user_id' ], kind: 'Hash' }
      indexingPolicy: { indexingMode: 'consistent', automatic: true, includedPaths: [ { path: '/*' } ] }
    }
  }
}

resource incidents 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers@2024-05-15' = {
  name: 'IncidentHistory'
  parent: db
  properties: {
    resource: {
      id: 'IncidentHistory'
      partitionKey: { paths: [ '/scenarioId' ], kind: 'Hash' }
    }
  }
}

// Cosmos Built-in Data Contributor role assignment for AKS UAMI
resource sqlRoleAssignment 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2024-05-15' = {
  name: guid(cosmos.id, aksUamiPrincipalId, 'data-contributor')
  parent: cosmos
  properties: {
    roleDefinitionId: '${cosmos.id}/sqlRoleDefinitions/00000000-0000-0000-0000-000000000002'
    principalId: aksUamiPrincipalId
    scope: cosmos.id
  }
}

resource pe 'Microsoft.Network/privateEndpoints@2023-11-01' = {
  name: '${accountName}-pe'
  location: location
  properties: {
    subnet: { id: privateEndpointSubnetId }
    privateLinkServiceConnections: [
      {
        name: 'cosmos'
        properties: {
          privateLinkServiceId: cosmos.id
          groupIds: [ 'Sql' ]
        }
      }
    ]
  }
}

resource peDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-11-01' = {
  name: 'default'
  parent: pe
  properties: {
    privateDnsZoneConfigs: [
      { name: 'cosmos', properties: { privateDnsZoneId: privateDnsZoneIdCosmos } }
    ]
  }
}

resource diag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-la'
  scope: cosmos
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      { categoryGroup: 'allLogs', enabled: true }
    ]
    metrics: [ { category: 'AllMetrics', enabled: true } ]
  }
}

output accountId string = cosmos.id
output accountName string = cosmos.name
output endpoint string = cosmos.properties.documentEndpoint
output databaseName string = db.name
output containerName string = container.name
