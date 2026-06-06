param prefix string
param env string
param location string
param subnetId string
@secure()
param adminPassword string
param logAnalyticsWorkspaceId string
param tags object

var vmName = '${prefix}-onprem-vm'

resource nic 'Microsoft.Network/networkInterfaces@2023-11-01' = {
  name: '${vmName}-nic'
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      { name: 'ipconfig1', properties: { subnet: { id: subnetId }, privateIPAllocationMethod: 'Dynamic' } }
    ]
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2024-03-01' = {
  name: vmName
  location: location
  tags: tags
  identity: { type: 'SystemAssigned' }
  properties: {
    hardwareProfile: { vmSize: 'Standard_B2s' }
    osProfile: {
      computerName: vmName
      adminUsername: 'azureuser'
      adminPassword: adminPassword
      linuxConfiguration: { disablePasswordAuthentication: false }
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-jammy'
        sku: '22_04-lts-gen2'
        version: 'latest'
      }
      osDisk: { createOption: 'FromImage', managedDisk: { storageAccountType: 'Standard_LRS' } }
    }
    networkProfile: { networkInterfaces: [ { id: nic.id } ] }
  }
}

resource ama 'Microsoft.Compute/virtualMachines/extensions@2024-03-01' = {
  name: 'AzureMonitorLinuxAgent'
  parent: vm
  location: location
  properties: {
    publisher: 'Microsoft.Azure.Monitor'
    type: 'AzureMonitorLinuxAgent'
    typeHandlerVersion: '1.27'
    autoUpgradeMinorVersion: true
  }
}

// Minimal DCR: Warning+ syslog from auth/daemon/kern/syslog facilities only
resource dcr 'Microsoft.Insights/dataCollectionRules@2022-06-01' = {
  name: '${vmName}-syslog-dcr'
  location: location
  tags: tags
  properties: {
    dataSources: {
      syslog: [
        {
          name: 'syslog-minimal'
          streams: [ 'Microsoft-Syslog' ]
          facilityNames: [ 'syslog', 'auth', 'daemon', 'kern', 'user', 'cron' ]
          logLevels: [ 'Debug', 'Info', 'Notice', 'Warning', 'Error', 'Critical', 'Alert', 'Emergency' ]
        }
      ]
    }
    destinations: {
      logAnalytics: [
        {
          name: 'law-dest'
          workspaceResourceId: logAnalyticsWorkspaceId
        }
      ]
    }
    dataFlows: [
      {
        streams: [ 'Microsoft-Syslog' ]
        destinations: [ 'law-dest' ]
      }
    ]
  }
}

resource dcrAssoc 'Microsoft.Insights/dataCollectionRuleAssociations@2022-06-01' = {
  name: '${vmName}-syslog-assoc'
  scope: vm
  properties: {
    dataCollectionRuleId: dcr.id
  }
}

output vmId string = vm.id
output vmName string = vm.name
output vmPrincipalId string = vm.identity.principalId
output laId string = logAnalyticsWorkspaceId
