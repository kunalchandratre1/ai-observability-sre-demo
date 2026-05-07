param prefix string
param env string
param location string
param aksUamiPrincipalId string
param tags object

var acrName = take(replace('${prefix}acr${env}${uniqueString(resourceGroup().id)}', '-', ''), 50)

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: acrName
  location: location
  tags: tags
  sku: { name: 'Standard' }
  properties: {
    adminUserEnabled: false
    publicNetworkAccess: 'Enabled'
  }
}

var roleAcrPull = '7f951dda-4ed3-4680-a7ca-43fe172d538d'

resource raAcrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acr.id, aksUamiPrincipalId, roleAcrPull)
  scope: acr
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleAcrPull)
    principalId: aksUamiPrincipalId
    principalType: 'ServicePrincipal'
  }
}

output acrId string = acr.id
output loginServer string = acr.properties.loginServer
output acrName string = acr.name
