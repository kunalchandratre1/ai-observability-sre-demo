param prefix string
param env string
param location string
param vnetAddressSpace string
param onPremVnetAddressSpace string
param vpnGatewayEnabled bool
param firewallSku string
param tags object

var hubName = '${prefix}-vnet-${env}'
var onPremVnetName = '${prefix}-onprem-vnet-${env}'
var fwName = '${prefix}-fw-${env}'
var fwPipName = '${prefix}-fw-pip-${env}'
var fwMgmtPipName = '${prefix}-fw-mgmt-pip-${env}'
var fwPolicyName = '${prefix}-fw-policy-${env}'
var vpnPipName = '${prefix}-vpn-pip-${env}'
var vpnGwName = '${prefix}-vpn-gw-${env}'

// NSG required by APIM when deployed into a VNet subnet
resource apimNsg 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: '${prefix}-nsg-apim-${env}'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'Allow-APIM-Management'
        properties: {
          priority: 100
          protocol: 'Tcp'
          access: 'Allow'
          direction: 'Inbound'
          sourceAddressPrefix: 'ApiManagement'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRange: '3443'
        }
      }
      {
        name: 'Allow-HTTPS-Inbound'
        properties: {
          priority: 110
          protocol: 'Tcp'
          access: 'Allow'
          direction: 'Inbound'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRange: '443'
        }
      }
      {
        name: 'Allow-AzureLoadBalancer'
        properties: {
          priority: 120
          protocol: 'Tcp'
          access: 'Allow'
          direction: 'Inbound'
          sourceAddressPrefix: 'AzureLoadBalancer'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRange: '6390'
        }
      }
      {
        name: 'Allow-Storage-Outbound'
        properties: {
          priority: 100
          protocol: 'Tcp'
          access: 'Allow'
          direction: 'Outbound'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: 'Storage'
          destinationPortRange: '443'
        }
      }
      {
        name: 'Allow-SQL-Outbound'
        properties: {
          priority: 110
          protocol: 'Tcp'
          access: 'Allow'
          direction: 'Outbound'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: 'Sql'
          destinationPortRange: '1433'
        }
      }
      {
        name: 'Allow-KeyVault-Outbound'
        properties: {
          priority: 120
          protocol: 'Tcp'
          access: 'Allow'
          direction: 'Outbound'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: 'AzureKeyVault'
          destinationPortRange: '443'
        }
      }
      {
        name: 'Allow-EventHub-Outbound'
        properties: {
          priority: 130
          protocol: 'Tcp'
          access: 'Allow'
          direction: 'Outbound'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: 'EventHub'
          destinationPortRange: '5671'
        }
      }
    ]
  }
}

resource hub 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: hubName
  location: location
  tags: tags
  dependsOn: [ apimNsg ]
  properties: {
    addressSpace: { addressPrefixes: [ vnetAddressSpace ] }
    subnets: [
      { name: 'snet-aks',     properties: { addressPrefix: cidrSubnet(vnetAddressSpace, 22, 0) } }
      { name: 'snet-pe',      properties: { addressPrefix: cidrSubnet(vnetAddressSpace, 24, 4), privateEndpointNetworkPolicies: 'Disabled' } }
      { name: 'snet-apim',    properties: { addressPrefix: cidrSubnet(vnetAddressSpace, 24, 5), networkSecurityGroup: { id: apimNsg.id } } }
      { name: 'AzureFirewallSubnet',           properties: { addressPrefix: cidrSubnet(vnetAddressSpace, 26, 24) } }
      { name: 'AzureFirewallManagementSubnet',  properties: { addressPrefix: cidrSubnet(vnetAddressSpace, 26, 26) } }
      { name: 'GatewaySubnet',                  properties: { addressPrefix: cidrSubnet(vnetAddressSpace, 27, 50) } }
    ]
  }
}

resource onPremVnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: onPremVnetName
  location: location
  tags: tags
  properties: {
    addressSpace: { addressPrefixes: [ onPremVnetAddressSpace ] }
    subnets: [
      { name: 'snet-onprem', properties: { addressPrefix: cidrSubnet(onPremVnetAddressSpace, 24, 0) } }
    ]
  }
}

resource peerHubToOnPrem 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-11-01' = {
  name: '${hub.name}/to-onprem'
  properties: {
    remoteVirtualNetwork: { id: onPremVnet.id }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
  }
}

resource peerOnPremToHub 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-11-01' = {
  name: '${onPremVnet.name}/to-hub'
  properties: {
    remoteVirtualNetwork: { id: hub.id }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
  }
}

resource fwPip 'Microsoft.Network/publicIPAddresses@2023-11-01' = {
  name: fwPipName
  location: location
  sku: { name: 'Standard' }
  properties: { publicIPAllocationMethod: 'Static' }
}

resource fwMgmtPip 'Microsoft.Network/publicIPAddresses@2023-11-01' = {
  name: fwMgmtPipName
  location: location
  sku: { name: 'Standard' }
  properties: { publicIPAllocationMethod: 'Static' }
}

// Basic tier requires a Firewall Policy (classic rules not supported)
resource fwPolicy 'Microsoft.Network/firewallPolicies@2023-11-01' = {
  name: fwPolicyName
  location: location
  tags: tags
  properties: {
    sku: { tier: firewallSku }
  }
}

resource fw 'Microsoft.Network/azureFirewalls@2023-11-01' = {
  name: fwName
  location: location
  tags: tags
  properties: {
    sku: { name: 'AZFW_VNet', tier: firewallSku }
    firewallPolicy: { id: fwPolicy.id }
    ipConfigurations: [
      {
        name: 'fwipconf'
        properties: {
          subnet: { id: '${hub.id}/subnets/AzureFirewallSubnet' }
          publicIPAddress: { id: fwPip.id }
        }
      }
    ]
    managementIpConfiguration: {
      name: 'fwmgmtipconf'
      properties: {
        subnet: { id: '${hub.id}/subnets/AzureFirewallManagementSubnet' }
        publicIPAddress: { id: fwMgmtPip.id }
      }
    }
  }
}

resource vpnPip 'Microsoft.Network/publicIPAddresses@2023-11-01' = if (vpnGatewayEnabled) {
  name: vpnPipName
  location: location
  sku: { name: 'Standard' }
  properties: { publicIPAllocationMethod: 'Static' }
}

resource vpnGw 'Microsoft.Network/virtualNetworkGateways@2023-11-01' = if (vpnGatewayEnabled) {
  name: vpnGwName
  location: location
  properties: {
    gatewayType: 'Vpn'
    vpnType: 'RouteBased'
    sku: { name: 'VpnGw1', tier: 'VpnGw1' }
    ipConfigurations: [
      {
        name: 'vpnGwIpConfig'
        properties: {
          subnet: { id: '${hub.id}/subnets/GatewaySubnet' }
          publicIPAddress: { id: vpnPip.id }
        }
      }
    ]
  }
}

// ----------------- Private DNS Zones for PE
var dnsZones = [
  'privatelink.documents.azure.com'
  'privatelink.vaultcore.azure.net'
  'privatelink.servicebus.windows.net'
  'privatelink.redis.cache.windows.net'
  'privatelink.cognitiveservices.azure.com'
  'privatelink.openai.azure.com'
  'privatelink.azurecr.io'
  'privatelink.eventhub.windows.net'
]

resource zones 'Microsoft.Network/privateDnsZones@2020-06-01' = [for z in dnsZones: {
  name: z
  location: 'global'
  tags: tags
}]

resource zoneLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = [for (z, i) in dnsZones: {
  name: '${zones[i].name}/link-hub'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: { id: hub.id }
  }
  dependsOn: [ zones ]
}]

output hubVnetId string = hub.id
output aksSubnetId string = '${hub.id}/subnets/snet-aks'
output peSubnetId string = '${hub.id}/subnets/snet-pe'
output apimSubnetId string = '${hub.id}/subnets/snet-apim'
output onPremSubnetId string = '${onPremVnet.id}/subnets/snet-onprem'
output firewallId string = fw.id
output privateDnsZoneIdCosmos string = zones[0].id
output privateDnsZoneIdKv string = zones[1].id
output privateDnsZoneIdSb string = zones[2].id
output privateDnsZoneIdRedis string = zones[3].id
output privateDnsZoneIdCognitive string = zones[4].id
output privateDnsZoneIdOpenAi string = zones[5].id
output privateDnsZoneIdAcr string = zones[6].id
output privateDnsZoneIdEventHub string = zones[7].id
