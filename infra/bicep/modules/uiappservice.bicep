@description('Resource naming prefix')
param prefix string

@description('Environment suffix')
param env string

@description('Azure region')
param location string = resourceGroup().location

param tags object = {}

var planName = '${prefix}-ui-plan-${env}'
var appName  = '${prefix}-ui-${env}'

resource appServicePlan 'Microsoft.Web/serverfarms@2023-01-01' = {
  name: planName
  location: location
  tags: tags
  sku: {
    name: 'F1'
    tier: 'Free'
  }
  properties: {}
}

resource webApp 'Microsoft.Web/sites@2023-01-01' = {
  name: appName
  location: location
  tags: tags
  properties: {
    serverFarmId: appServicePlan.id
    httpsOnly: true
    siteConfig: {
      defaultDocuments: ['index.html']
      httpLoggingEnabled: false
      // Serve static content; no runtime required
      use32BitWorkerProcess: true
    }
  }
}

output webAppName string = webApp.name
output webAppUrl  string = 'https://${webApp.properties.defaultHostName}'
