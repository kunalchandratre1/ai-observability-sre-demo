param prefix string
param env string
param location string
param logAnalyticsSku string
param tags object

resource la 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: '${prefix}-la-${env}'
  location: location
  tags: tags
  properties: {
    sku: { name: logAnalyticsSku }
    retentionInDays: 30
    features: { enableLogAccessUsingOnlyResourcePermissions: true }
  }
}

output logAnalyticsWorkspaceId string = la.id
output logAnalyticsWorkspaceName string = la.name
