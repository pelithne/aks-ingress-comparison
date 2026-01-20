// ============================================================================
// Network Module - Virtual Network with Subnets
// ============================================================================
// Creates the virtual network with subnets for:
// - AKS cluster with Application Gateway for Containers
// - AKS cluster with managed NGINX ingress
// - Application Gateway for Containers subnet (with delegation)
// ============================================================================

@description('Azure region for deployment')
param location string

@description('Virtual network name')
param vnetName string

@description('Virtual network address prefix')
param vnetAddressPrefix string

@description('Subnet configurations')
param subnets object

@description('Resource tags')
param tags object

// ============================================================================
// Resources
// ============================================================================

// Network Security Group for AKS subnets
resource nsgAks 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: '${vnetName}-nsg-aks'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'AllowHTTP'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '80'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'AllowHTTPS'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '443'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}

// Virtual Network
resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressPrefix
      ]
    }
    subnets: [
      // AKS with AGC subnet
      {
        name: subnets.aksAgc.name
        properties: {
          addressPrefix: subnets.aksAgc.addressPrefix
          networkSecurityGroup: {
            id: nsgAks.id
          }
          privateEndpointNetworkPolicies: 'Disabled'
          privateLinkServiceNetworkPolicies: 'Enabled'
        }
      }
      // AKS with NGINX subnet
      {
        name: subnets.aksNginx.name
        properties: {
          addressPrefix: subnets.aksNginx.addressPrefix
          networkSecurityGroup: {
            id: nsgAks.id
          }
          privateEndpointNetworkPolicies: 'Disabled'
          privateLinkServiceNetworkPolicies: 'Enabled'
        }
      }
      // Application Gateway for Containers subnet (requires delegation)
      {
        name: subnets.agc.name
        properties: {
          addressPrefix: subnets.agc.addressPrefix
          delegations: [
            {
              name: 'Microsoft.ServiceNetworking/trafficControllers'
              properties: {
                serviceName: 'Microsoft.ServiceNetworking/trafficControllers'
              }
            }
          ]
        }
      }
    ]
  }
}

// ============================================================================
// Outputs
// ============================================================================

@description('Virtual network resource ID')
output vnetId string = vnet.id

@description('Virtual network name')
output vnetName string = vnet.name

@description('AKS with AGC subnet resource ID')
output aksAgcSubnetId string = resourceId('Microsoft.Network/virtualNetworks/subnets', vnet.name, subnets.aksAgc.name)

@description('AKS with NGINX subnet resource ID')
output aksNginxSubnetId string = resourceId('Microsoft.Network/virtualNetworks/subnets', vnet.name, subnets.aksNginx.name)

@description('Application Gateway for Containers subnet resource ID')
output agcSubnetId string = resourceId('Microsoft.Network/virtualNetworks/subnets', vnet.name, subnets.agc.name)
