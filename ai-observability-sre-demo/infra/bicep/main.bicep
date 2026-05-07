targetScope = 'resourceGroup'

@minLength(3)
@maxLength(8)
param prefix string = 'aiosre'
param env string = 'demo'
param location string = resourceGroup().location

@description('Object id of the deploying user (for KV admin role)')
param deployerObjectId string = ''

param vnetAddressSpace string = '10.40.0.0/16'
param onPremVnetAddressSpace string = '10.50.0.0/16'

param aksNodeCount int = 2
param aksNodeSku string = 'Standard_D4s_v5'

param apimSku string = 'Developer'
param apimPublisherEmail string = 'sre-demo@example.com'
param apimPublisherName string = 'SRE Demo'

param adxSku string = 'Dev(No SLA)_Standard_E2a_v4'
param adxCapacity int = 1

param vpnGatewayEnabled bool = false
param onPremVmEnabled bool = true
@secure()
param onPremVmPassword string

param openAiChatDeployment string = 'gpt-4o-mini'
param openAiSttDeployment string = 'whisper'

var tags = {
  app: 'ai-observability-sre-demo'
  env: env
  owner: 'sre-demo'
}

// ----------------------------------------------------------------------
// 1. Network
// ----------------------------------------------------------------------
module network 'modules/network.bicep' = {
  name: 'network'
  params: {
    prefix: prefix
    env: env
    location: location
    vnetAddressSpace: vnetAddressSpace
    onPremVnetAddressSpace: onPremVnetAddressSpace
    vpnGatewayEnabled: vpnGatewayEnabled
    tags: tags
  }
}

// ----------------------------------------------------------------------
// 2. Identity, Key Vault, ACR
// ----------------------------------------------------------------------
module identity 'modules/identity.bicep' = {
  name: 'identity'
  params: {
    prefix: prefix
    env: env
    location: location
    tags: tags
  }
}

module kv 'modules/keyvault.bicep' = {
  name: 'keyvault'
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
  name: 'acr'
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
  name: 'monitoring'
  params: {
    prefix: prefix
    env: env
    location: location
    tags: tags
  }
}

module eventhubs 'modules/eventhubs.bicep' = {
  name: 'eventhubs'
  params: {
    prefix: prefix
    env: env
    location: location
    aksUamiPrincipalId: identity.outputs.aksUamiPrincipalId
    apimUamiPrincipalId: identity.outputs.apimUamiPrincipalId
    tags: tags
  }
}

module adx 'modules/adx.bicep' = {
  name: 'adx'
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
  name: 'grafana'
  params: {
    prefix: prefix
    env: env
    location: location
    monitorWorkspaceId: monitoring.outputs.monitorWorkspaceId
    adxClusterUri: adx.outputs.clusterUri
    tags: tags
  }
}

// ----------------------------------------------------------------------
// 4. Data services
// ----------------------------------------------------------------------
module cosmos 'modules/cosmos.bicep' = {
  name: 'cosmos'
  params: {
    prefix: prefix
    env: env
    location: location
    privateEndpointSubnetId: network.outputs.peSubnetId
    privateDnsZoneIdCosmos: network.outputs.privateDnsZoneIdCosmos
    aksUamiPrincipalId: identity.outputs.aksUamiPrincipalId
    logAnalyticsWorkspaceId: monitoring.outputs.logAnalyticsWorkspaceId
    tags: tags
  }
}

module servicebus 'modules/servicebus.bicep' = {
  name: 'servicebus'
  params: {
    prefix: prefix
    env: env
    location: location
    aksUamiPrincipalId: identity.outputs.aksUamiPrincipalId
    logAnalyticsWorkspaceId: monitoring.outputs.logAnalyticsWorkspaceId
    tags: tags
  }
}

module redis 'modules/redis.bicep' = {
  name: 'redis'
  params: {
    prefix: prefix
    env: env
    location: location
    logAnalyticsWorkspaceId: monitoring.outputs.logAnalyticsWorkspaceId
    tags: tags
  }
}

module speech 'modules/speech.bicep' = {
  name: 'speech'
  params: {
    prefix: prefix
    env: env
    location: location
    aksUamiPrincipalId: identity.outputs.aksUamiPrincipalId
    logAnalyticsWorkspaceId: monitoring.outputs.logAnalyticsWorkspaceId
    tags: tags
  }
}

module openai 'modules/openai.bicep' = {
  name: 'openai'
  params: {
    prefix: prefix
    env: env
    location: location
    aksUamiPrincipalId: identity.outputs.aksUamiPrincipalId
    logAnalyticsWorkspaceId: monitoring.outputs.logAnalyticsWorkspaceId
    chatDeploymentName: openAiChatDeployment
    sttDeploymentName: openAiSttDeployment
    tags: tags
  }
}

module onpremVm 'modules/onpremvm.bicep' = if (onPremVmEnabled) {
  name: 'onpremvm'
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
  name: 'aks'
  params: {
    prefix: prefix
    env: env
    location: location
    nodeCount: aksNodeCount
    nodeSku: aksNodeSku
    aksSubnetId: network.outputs.aksSubnetId
    aksUamiId: identity.outputs.aksUamiId
    monitorWorkspaceId: monitoring.outputs.monitorWorkspaceId
    logAnalyticsWorkspaceId: monitoring.outputs.logAnalyticsWorkspaceId
    grafanaId: grafana.outputs.grafanaId
    tags: tags
  }
}

// ----------------------------------------------------------------------
// 6. APIM (External, with VNet integration to reach AKS internal LB)
// ----------------------------------------------------------------------
module apim 'modules/apim.bicep' = {
  name: 'apim'
  params: {
    prefix: prefix
    env: env
    location: location
    sku: apimSku
    publisherEmail: apimPublisherEmail
    publisherName: apimPublisherName
    apimSubnetId: network.outputs.apimSubnetId
    apimUamiId: identity.outputs.apimUamiId
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
