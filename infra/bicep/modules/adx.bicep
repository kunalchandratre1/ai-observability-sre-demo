param prefix string
param env string
param location string
param sku string
param capacity int
param eventHubAksOtelId string
param eventHubApimDiagId string
param sreAgentUamiPrincipalId string
param tags object

var skuParts = split(sku, '_')
// sku format like: "Dev(No SLA)_Standard_E2a_v4"
// Tier is the first segment, name is the full string. Use tier as text.
var tier = startsWith(sku, 'Dev') ? 'Basic' : 'Standard'

resource cluster 'Microsoft.Kusto/clusters@2023-08-15' = {
  name: '${prefix}adx${env}${take(uniqueString(resourceGroup().id), 6)}'
  location: location
  tags: tags
  sku: { name: sku, tier: tier, capacity: capacity }
  identity: { type: 'SystemAssigned' }
  properties: {
    enableStreamingIngest: true
    enablePurge: false
  }
}

resource db 'Microsoft.Kusto/clusters/databases@2023-08-15' = {
  name: 'observability'
  parent: cluster
  location: location
  kind: 'ReadWrite'
  properties: {
    softDeletePeriod: 'P30D'
    hotCachePeriod: 'P7D'
  }
}

// SRE Agent UAMI gets Database Viewer role on the DB (Reader connector pattern).
resource sreReader 'Microsoft.Kusto/clusters/databases/principalAssignments@2023-08-15' = {
  name: 'sre-agent-viewer'
  parent: db
  properties: {
    principalId: sreAgentUamiPrincipalId
    principalType: 'App'
    role: 'Viewer'
    tenantId: subscription().tenantId
  }
}

// ADX cluster managed identity must be granted the Azure Event Hubs Data Receiver role on the hubs (assigned at module composition by Authorization/roleAssignments).
var roleEhReceiver = 'a638d3c7-ab3a-418d-83e6-5f17a39d4fde'

resource raEhAks 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(eventHubAksOtelId, cluster.id, 'eh-receiver-aks')
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleEhReceiver)
    principalId: cluster.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Event Hub data connections (one per table that's fed from EH). The actual table/mapping is created by /infra/adx/schema.kql via control-plane after deploy.
// We declare DataConnections in code; tables/mappings must exist before connection creation.
// To keep deployment idempotent, the script /infra/scripts/15-bootstrap-adx.sh creates the schema first, then re-runs `az deployment` to create the data connections (or uses az kusto data-connection create directly).

output clusterId string = cluster.id
output clusterName string = cluster.name
output clusterUri string = cluster.properties.uri
output databaseName string = db.name
output clusterPrincipalId string = cluster.identity.principalId
