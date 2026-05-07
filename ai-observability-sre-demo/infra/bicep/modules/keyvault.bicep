param prefix string
param env string
param location string
param deployerObjectId string
param aksUamiPrincipalId string
param apimUamiPrincipalId string
param sreAgentUamiPrincipalId string
param privateEndpointSubnetId string
param privateDnsZoneIdKv string
param tags object

var kvName = take(replace('${prefix}kv${env}${uniqueString(resourceGroup().id)}', '-', ''), 24)

resource kv 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: kvName
  location: location
  tags: tags
  properties: {
    sku: { family: 'A', name: 'standard' }
    tenantId: subscription().tenantId
    enableRbacAuthorization: true
    enableSoftDelete: true
    publicNetworkAccess: 'Enabled' // demo simplicity; production should use private only
    networkAcls: { defaultAction: 'Allow', bypass: 'AzureServices' }
  }
}

// RBAC: Key Vault Secrets User for AKS / APIM / SRE; Key Vault Administrator for deployer
var roleSecretsUser = '4633458b-17de-408a-b874-0445c86b69e6'
var roleAdmin = '00482a5a-887f-4fb3-b363-3b7fe8e74483'

resource raDeployer 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(deployerObjectId)) {
  name: guid(kv.id, deployerObjectId, roleAdmin)
  scope: kv
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleAdmin)
    principalId: deployerObjectId
    principalType: 'User'
  }
}

resource raAks 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(kv.id, aksUamiPrincipalId, roleSecretsUser)
  scope: kv
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleSecretsUser)
    principalId: aksUamiPrincipalId
    principalType: 'ServicePrincipal'
  }
}

resource raApim 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(kv.id, apimUamiPrincipalId, roleSecretsUser)
  scope: kv
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleSecretsUser)
    principalId: apimUamiPrincipalId
    principalType: 'ServicePrincipal'
  }
}

resource raSre 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(kv.id, sreAgentUamiPrincipalId, roleSecretsUser)
  scope: kv
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleSecretsUser)
    principalId: sreAgentUamiPrincipalId
    principalType: 'ServicePrincipal'
  }
}

output kvId string = kv.id
output kvName string = kv.name
output kvUri string = kv.properties.vaultUri
