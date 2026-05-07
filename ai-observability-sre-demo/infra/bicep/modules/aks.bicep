param prefix string
param env string
param location string
param nodeCount int
param nodeSku string
param aksSubnetId string
param aksUamiId string
param monitorWorkspaceId string
param logAnalyticsWorkspaceId string
param grafanaId string
param tags object

resource aks 'Microsoft.ContainerService/managedClusters@2024-09-01' = {
  name: '${prefix}-aks-${env}'
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${aksUamiId}': {} }
  }
  properties: {
    dnsPrefix: '${prefix}-aks-${env}'
    enableRBAC: true
    oidcIssuerProfile: { enabled: true }
    securityProfile: {
      workloadIdentity: { enabled: true }
    }
    networkProfile: {
      networkPlugin: 'azure'
      networkPolicy: 'azure'
      serviceCidr: '172.16.0.0/16'
      dnsServiceIP: '172.16.0.10'
    }
    agentPoolProfiles: [
      {
        name: 'system'
        count: 1
        vmSize: 'Standard_D2s_v5'
        mode: 'System'
        osType: 'Linux'
        vnetSubnetID: aksSubnetId
      }
      {
        name: 'user'
        count: nodeCount
        vmSize: nodeSku
        mode: 'User'
        osType: 'Linux'
        vnetSubnetID: aksSubnetId
      }
    ]
    azureMonitorProfile: {
      metrics: {
        enabled: true
        kubeStateMetrics: { metricLabelsAllowlist: '*', metricAnnotationsAllowList: '' }
      }
    }
    addonProfiles: {
      omsagent: {
        enabled: true
        config: { logAnalyticsWorkspaceResourceID: logAnalyticsWorkspaceId }
      }
    }
  }
}

// Container Insights / Managed Prometheus is plumbed via azureMonitorProfile (KSM) + DCR association in /infra/scripts/30-deploy-aks.sh
// Workload identity federated credentials are created in /infra/scripts/30-deploy-aks.sh (post-deploy) with `az identity federated-credential create`.

output aksId string = aks.id
output aksName string = aks.name
output oidcIssuerUrl string = aks.properties.oidcIssuerProfile.issuerURL
// Internal LB FQDN is created by the ingress controller post-deploy. Placeholder used in APIM module for backend URL; updated by 30-deploy-aks.sh via APIM backend update.
output internalIngressFqdnPlaceholder string = '${prefix}-ingress.internal.local'
