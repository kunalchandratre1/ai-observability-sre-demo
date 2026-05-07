param prefix string
param env string
param location string
param tags object

resource aksUami 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${prefix}-aks-uami-${env}'
  location: location
  tags: tags
}

resource apimUami 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${prefix}-apim-uami-${env}'
  location: location
  tags: tags
}

resource sreAgentUami 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${prefix}-sre-uami-${env}'
  location: location
  tags: tags
}

output aksUamiId string = aksUami.id
output aksUamiPrincipalId string = aksUami.properties.principalId
output aksUamiClientId string = aksUami.properties.clientId
output apimUamiId string = apimUami.id
output apimUamiPrincipalId string = apimUami.properties.principalId
output sreAgentUamiId string = sreAgentUami.id
output sreAgentUamiPrincipalId string = sreAgentUami.properties.principalId
