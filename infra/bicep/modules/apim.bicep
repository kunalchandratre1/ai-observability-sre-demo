param prefix string
param env string
param location string
param sku string
param publisherEmail string
param publisherName string
param apimSubnetId string
param apimUamiId string
param eventHubNamespaceName string
param apimDiagHubName string
param logAnalyticsWorkspaceId string
param backendBaseUrl string
param tags object

resource apim 'Microsoft.ApiManagement/service@2023-09-01-preview' = {
  name: '${prefix}-apim-${env}'
  location: location
  tags: tags
  sku: { name: sku, capacity: 1 }
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${apimUamiId}': {} }
  }
  properties: {
    publisherEmail: publisherEmail
    publisherName: publisherName
    virtualNetworkType: 'External'
    virtualNetworkConfiguration: { subnetResourceId: apimSubnetId }
  }
}

// Logger pointing at Event Hub via managed identity
resource ehLogger 'Microsoft.ApiManagement/service/loggers@2023-09-01-preview' = {
  name: 'eh-diag-logger'
  parent: apim
  properties: {
    loggerType: 'azureEventHub'
    description: 'APIM diagnostics -> Event Hub -> ADX'
    credentials: {
      endpointAddress: '${eventHubNamespaceName}.servicebus.windows.net'
      identityClientId: ''
      name: apimDiagHubName
    }
  }
}

resource voiceApi 'Microsoft.ApiManagement/service/apis@2023-09-01-preview' = {
  name: 'voice-orders'
  parent: apim
  properties: {
    displayName: 'Voice Orders API'
    path: 'voice'
    protocols: [ 'https' ]
    serviceUrl: backendBaseUrl
    subscriptionRequired: true
  }
}

resource voiceOp 'Microsoft.ApiManagement/service/apis/operations@2023-09-01-preview' = {
  name: 'submit-order'
  parent: voiceApi
  properties: {
    displayName: 'Submit Voice Order'
    method: 'POST'
    urlTemplate: '/orders'
  }
}

resource voiceOpHealth 'Microsoft.ApiManagement/service/apis/operations@2023-09-01-preview' = {
  name: 'get-health'
  parent: voiceApi
  properties: {
    displayName: 'Health'
    method: 'GET'
    urlTemplate: '/health'
  }
}

// Inbound + diagnostic policies are uploaded by /infra/apim/policies/*.xml via /infra/scripts/35-apim-policies.sh
// (because Bicep policy contents are large XML blobs — separating keeps the module clean).

resource diag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-la'
  scope: apim
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [ { categoryGroup: 'allLogs', enabled: true } ]
    metrics: [ { category: 'AllMetrics', enabled: true } ]
  }
}

output apimId string = apim.id
output apimName string = apim.name
output gatewayUrl string = apim.properties.gatewayUrl
output ehLoggerName string = ehLogger.name
