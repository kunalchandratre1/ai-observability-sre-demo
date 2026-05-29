targetScope = 'resourceGroup'

@minLength(3)
@maxLength(8)
param prefix string = 'aiosre'
param env string = 'demo'
param location string = resourceGroup().location

@description('Object id of the deploying user (for KV admin role)')
param deployerObjectId string = 'bf41e426-aa10-40c5-a893-118908206a75'

param vnetAddressSpace string = '10.40.0.0/16'
param onPremVnetAddressSpace string = '10.50.0.0/16'

param aksNodeCount int = 2
param aksSystemNodeSku string = 'Standard_B2s'
param aksNodeSku string = 'Standard_B2s'

param apimSku string = 'Developer'
param apimPublisherEmail string = 'sre-demo@example.com'
param apimPublisherName string = 'SRE Demo'

param adxSku string = 'Dev(No SLA)_Standard_D11_v2'
param adxCapacity int = 1
param firewallSku string = 'Basic'
param eventHubSku string = 'Standard'
param grafanaSku string = 'Standard'
param logAnalyticsSku string = 'PerGB2018'
param cosmosConsistency string = 'Session'
param serviceBusSku string = 'Standard'
param redisSku string = 'Basic'
param speechSku string = 'S0'
param openAiSku string = 'S0'

param vpnGatewayEnabled bool = false
param onPremVmEnabled bool = true
@secure()
param onPremVmPassword string

param openAiChatDeployment string = 'gpt-4o-mini'

@description('Short suffix appended to every child-deployment name so ARM does not block on re-runs (e.g. "r1", "r2").')
@maxLength(8)
param deploymentSuffix string = 'r1'

var tags = {
  app: 'ai-observability-sre-demo'
  env: env
  owner: 'sre-demo'
}

// ----------------------------------------------------------------------
// 1. Network
// ----------------------------------------------------------------------
module network 'modules/network.bicep' = {
  name: 'network${deploymentSuffix}'
  params: {
    prefix: prefix
    env: env
    location: location
    vnetAddressSpace: vnetAddressSpace
    onPremVnetAddressSpace: onPremVnetAddressSpace
    vpnGatewayEnabled: vpnGatewayEnabled
    firewallSku: firewallSku
    tags: tags
  }
}

// ----------------------------------------------------------------------
// 2. Identity, Key Vault, ACR
// ----------------------------------------------------------------------
module identity 'modules/identity.bicep' = {
  name: 'identity${deploymentSuffix}'
  params: {
    prefix: prefix
    env: env
    location: location
    tags: tags
  }
}

module kv 'modules/keyvault.bicep' = {
  name: 'keyvault${deploymentSuffix}'
  params: {
    prefix: prefix
    env: env
    location: location
    deployerObjectId: deployerObjectId
    aksUamiPrincipalId: identity.outputs.aksUamiPrincipalId
    apimUamiPrincipalId: identity.outputs.apimUamiPrincipalId
    sreAgentUamiPrincipalId: identity.outputs.sreAgentUamiPrincipalId
    privateEndpointSubnetId: network.outputs.peSubnetId
    privateDnsZoneIdKv: network.outputs.privateDnsZoneIdKv
    tags: tags
  }
}

module acr 'modules/acr.bicep' = {
  name: 'acr${deploymentSuffix}'
  params: {
    prefix: prefix
    env: env
    location: location
    aksUamiPrincipalId: identity.outputs.aksUamiPrincipalId
    tags: tags
  }
}

// ----------------------------------------------------------------------
// 3. Monitoring (LA + Monitor workspace + Grafana + ADX + Event Hubs)
// ----------------------------------------------------------------------
module monitoring 'modules/monitoring.bicep' = {
  name: 'monitoring${deploymentSuffix}'
  params: {
    prefix: prefix
    env: env
    location: location
    logAnalyticsSku: logAnalyticsSku
    tags: tags
  }
}

module eventhubs 'modules/eventhubs.bicep' = {
  name: 'eventhubs${deploymentSuffix}'
  params: {
    prefix: prefix
    env: env
    location: location
    aksUamiPrincipalId: identity.outputs.aksUamiPrincipalId
    apimUamiPrincipalId: identity.outputs.apimUamiPrincipalId
    namespaceSku: eventHubSku
    tags: tags
  }
}

module adx 'modules/adx.bicep' = {
  name: 'adx${deploymentSuffix}'
  params: {
    prefix: prefix
    env: env
    location: location
    sku: adxSku
    capacity: adxCapacity
    eventHubAksOtelId: eventhubs.outputs.aksOtelHubId
    eventHubApimDiagId: eventhubs.outputs.apimDiagHubId
    sreAgentUamiPrincipalId: identity.outputs.sreAgentUamiPrincipalId
    tags: tags
  }
}

module grafana 'modules/grafana.bicep' = {
  name: 'grafana${deploymentSuffix}'
  params: {
    prefix: prefix
    env: env
    location: location
    monitorWorkspaceId: monitoring.outputs.monitorWorkspaceId
    adxClusterUri: adx.outputs.clusterUri
    grafanaSku: grafanaSku
    tags: tags
  }
}

// ----------------------------------------------------------------------
// 4. Data services
// ----------------------------------------------------------------------
module cosmos 'modules/cosmos.bicep' = {
  name: 'cosmos${deploymentSuffix}'
  params: {
    prefix: prefix
    env: env
    location: location
    privateEndpointSubnetId: network.outputs.peSubnetId
    privateDnsZoneIdCosmos: network.outputs.privateDnsZoneIdCosmos
    aksUamiPrincipalId: identity.outputs.aksUamiPrincipalId
    consistencyLevel: cosmosConsistency
    logAnalyticsWorkspaceId: monitoring.outputs.logAnalyticsWorkspaceId
    tags: tags
  }
}

module servicebus 'modules/servicebus.bicep' = {
  name: 'servicebus${deploymentSuffix}'
  params: {
    prefix: prefix
    env: env
    location: location
    aksUamiPrincipalId: identity.outputs.aksUamiPrincipalId
    namespaceSku: serviceBusSku
    logAnalyticsWorkspaceId: monitoring.outputs.logAnalyticsWorkspaceId
    tags: tags
  }
}

module redis 'modules/redis.bicep' = {
  name: 'redis${deploymentSuffix}'
  params: {
    prefix: prefix
    env: env
    location: location
    redisSku: redisSku
    logAnalyticsWorkspaceId: monitoring.outputs.logAnalyticsWorkspaceId
    tags: tags
  }
}

module speech 'modules/speech.bicep' = {
  name: 'speech${deploymentSuffix}'
  params: {
    prefix: prefix
    env: env
    location: location
    aksUamiPrincipalId: identity.outputs.aksUamiPrincipalId
    speechSku: speechSku
    logAnalyticsWorkspaceId: monitoring.outputs.logAnalyticsWorkspaceId
    tags: tags
  }
}

module openai 'modules/openai.bicep' = {
  name: 'openai${deploymentSuffix}'
  params: {
    prefix: prefix
    env: env
    location: location
    aksUamiPrincipalId: identity.outputs.aksUamiPrincipalId
    logAnalyticsWorkspaceId: monitoring.outputs.logAnalyticsWorkspaceId
    openAiSku: openAiSku
    chatDeploymentName: openAiChatDeployment
    tags: tags
  }
}

module onpremVm 'modules/onpremvm.bicep' = if (onPremVmEnabled) {
  name: 'onpremvm${deploymentSuffix}'
  params: {
    prefix: prefix
    env: env
    location: location
    subnetId: network.outputs.onPremSubnetId
    adminPassword: onPremVmPassword
    logAnalyticsWorkspaceId: monitoring.outputs.logAnalyticsWorkspaceId
    tags: tags
  }
}

// ----------------------------------------------------------------------
// 5. AKS
// ----------------------------------------------------------------------
module aks 'modules/aks.bicep' = {
  name: 'aks${deploymentSuffix}'
  params: {
    prefix: prefix
    env: env
    location: location
    nodeCount: aksNodeCount
    systemNodeSku: aksSystemNodeSku
    nodeSku: aksNodeSku
    aksSubnetId: network.outputs.aksSubnetId
    aksUamiId: identity.outputs.aksUamiId
    monitorWorkspaceId: monitoring.outputs.monitorWorkspaceId
    grafanaId: grafana.outputs.grafanaId
    tags: tags
  }
}

// ----------------------------------------------------------------------
// 6. APIM (External, with VNet integration to reach AKS internal LB)
// ----------------------------------------------------------------------
module apim 'modules/apim.bicep' = {
  name: 'apim${deploymentSuffix}'
  params: {
    prefix: prefix
    env: env
    location: location
    sku: apimSku
    publisherEmail: apimPublisherEmail
    publisherName: apimPublisherName
    apimSubnetId: network.outputs.apimSubnetId
    apimUamiId: identity.outputs.apimUamiId
    apimUamiClientId: identity.outputs.apimUamiClientId
    eventHubNamespaceName: eventhubs.outputs.namespaceName
    apimDiagHubName: eventhubs.outputs.apimDiagHubName
    logAnalyticsWorkspaceId: monitoring.outputs.logAnalyticsWorkspaceId
    backendBaseUrl: 'http://${aks.outputs.internalIngressFqdnPlaceholder}/api'
    tags: tags
  }
}

output rgName string = resourceGroup().name
output aksName string = aks.outputs.aksName
output acrLoginServer string = acr.outputs.loginServer
output apimGatewayUrl string = apim.outputs.gatewayUrl
output adxClusterUri string = adx.outputs.clusterUri
output adxDatabaseName string = adx.outputs.databaseName
output grafanaEndpoint string = grafana.outputs.endpoint
output cosmosAccountName string = cosmos.outputs.accountName
output keyVaultName string = kv.outputs.kvName
output eventHubNamespace string = eventhubs.outputs.namespaceName
output aksUamiClientId string = identity.outputs.aksUamiClientId
output aksOidcIssuerUrl string = aks.outputs.oidcIssuerUrl
output aksSystemNodeSku string = aksSystemNodeSku
output aksUserNodeSku string = aksNodeSku
output sreAgentUamiPrincipalId string = identity.outputs.sreAgentUamiPrincipalId

// SRE Agent UAMI: Reader on RG = full visibility into all resource properties, ARM metadata, configs
var readerRoleId = 'acdd72a7-3385-48ef-bd42-f606fba81ae7'
resource sreReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, 'sre-agent-uami', readerRoleId)
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', readerRoleId)
    principalId: identity.outputs.sreAgentUamiPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// SRE Agent UAMI: Monitoring Reader on RG = read metrics, logs, alerts, diagnostic settings
var monitoringReaderRoleId = '43d0d8ad-25c7-4714-9337-8ba259a9fe05'
resource sreMonitoringReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, 'sre-agent-uami', monitoringReaderRoleId)
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', monitoringReaderRoleId)
    principalId: identity.outputs.sreAgentUamiPrincipalId
    principalType: 'ServicePrincipal'
  }
}
