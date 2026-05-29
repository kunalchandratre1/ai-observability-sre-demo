// Azure Storage Account with static website hosting for the demo UI.
// Files are uploaded post-deploy by 45-deploy-ui.ps1.
param prefix string
param env string
param location string
param tags object

// Storage account name: lowercase alphanum only, max 24 chars
var storageName = '${replace(prefix, '-', '')}ui${replace(env, '-', '')}'

resource uiStorage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageName
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: { name: 'Standard_LRS' }
  properties: {
    accessTier: 'Hot'
    allowBlobPublicAccess: true          // required for static website anonymous read
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    networkAcls: {
      defaultAction: 'Allow'             // public; restrict in production
    }
  }
}

// Enable static website feature
resource staticWebsite 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  name: 'default'
  parent: uiStorage
  properties: {
    cors: {
      corsRules: [
        {
          allowedOrigins: ['*']
          allowedMethods: ['GET', 'HEAD', 'OPTIONS']
          allowedHeaders: ['*']
          exposedHeaders: ['*']
          maxAgeInSeconds: 3600
        }
      ]
    }
  }
}

output storageAccountName string = uiStorage.name
output primaryEndpoint string = uiStorage.properties.primaryEndpoints.web
output blobEndpoint string = uiStorage.properties.primaryEndpoints.blob
