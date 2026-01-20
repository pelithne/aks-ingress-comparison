// ============================================================================
// AKS Ingress Comparison - Application Gateway for Containers vs Managed NGINX
// ============================================================================
// This template deploys two AKS clusters with Azure CNI Powered by Cilium:
// 1. AKS cluster with Application Gateway for Containers (AGC)
// 2. AKS cluster with managed NGINX ingress controller
// Both clusters are configured similarly for fair performance comparison.
// ============================================================================

targetScope = 'resourceGroup'

// ============================================================================
// Parameters
// ============================================================================

@description('The Azure region for deployment')
param location string = resourceGroup().location

@description('Base name for all resources')
@minLength(3)
@maxLength(20)
param baseName string = 'aksIngress'

@description('VM size for AKS nodes')
param nodeVmSize string = 'Standard_D4s_v6'

@description('Number of nodes per cluster')
@minValue(1)
@maxValue(10)
param nodeCount int = 1

@description('Tags for all resources')
param tags object = {
  project: 'aks-ingress-comparison'
  purpose: 'performance-testing'
}

// ============================================================================
// Variables
// ============================================================================

var uniqueSuffix = uniqueString(resourceGroup().id)
var vnetName = '${baseName}-vnet-${uniqueSuffix}'
var logAnalyticsName = '${baseName}-logs-${uniqueSuffix}'

// Cluster names
var aksAgcName = '${baseName}-agc-${uniqueSuffix}'
var aksNginxName = '${baseName}-nginx-${uniqueSuffix}'

// Application Gateway for Containers name
var agcName = '${baseName}-agc-tc-${uniqueSuffix}'

// Network configuration
var vnetAddressPrefix = '10.0.0.0/8'

// Subnet configurations
var subnets = {
  // AKS with AGC cluster subnet
  aksAgc: {
    name: 'snet-aks-agc'
    addressPrefix: '10.1.0.0/16'
  }
  // AKS with NGINX cluster subnet  
  aksNginx: {
    name: 'snet-aks-nginx'
    addressPrefix: '10.2.0.0/16'
  }
  // Application Gateway for Containers subnet (requires delegation)
  agc: {
    name: 'snet-agc'
    addressPrefix: '10.3.0.0/24'
  }
}

// ============================================================================
// Resources
// ============================================================================

// Log Analytics Workspace for monitoring
resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: logAnalyticsName
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

// Virtual Network
module network 'modules/network.bicep' = {
  name: 'network-deployment'
  params: {
    location: location
    vnetName: vnetName
    vnetAddressPrefix: vnetAddressPrefix
    subnets: subnets
    tags: tags
  }
}

// AKS Cluster with Application Gateway for Containers
module aksAgc 'modules/aks-agc.bicep' = {
  name: 'aks-agc-deployment'
  params: {
    location: location
    clusterName: aksAgcName
    nodeVmSize: nodeVmSize
    nodeCount: nodeCount
    subnetId: network.outputs.aksAgcSubnetId
    logAnalyticsWorkspaceId: logAnalytics.id
    tags: union(tags, { ingressType: 'agc' })
  }
}

// AKS Cluster with Managed NGINX Ingress
module aksNginx 'modules/aks-nginx.bicep' = {
  name: 'aks-nginx-deployment'
  params: {
    location: location
    clusterName: aksNginxName
    nodeVmSize: nodeVmSize
    nodeCount: nodeCount
    subnetId: network.outputs.aksNginxSubnetId
    logAnalyticsWorkspaceId: logAnalytics.id
    tags: union(tags, { ingressType: 'nginx' })
  }
}

// Application Gateway for Containers (Traffic Controller)
module agc 'modules/agc.bicep' = {
  name: 'agc-deployment'
  params: {
    location: location
    name: agcName
    subnetId: network.outputs.agcSubnetId
    tags: tags
  }
}

// ============================================================================
// Outputs
// ============================================================================

@description('Resource group name')
output resourceGroupName string = resourceGroup().name

@description('AKS with AGC cluster name')
output aksAgcClusterName string = aksAgc.outputs.clusterName

@description('AKS with NGINX cluster name')
output aksNginxClusterName string = aksNginx.outputs.clusterName

@description('AKS with AGC FQDN')
output aksAgcFqdn string = aksAgc.outputs.controlPlaneFqdn

@description('AKS with NGINX FQDN')
output aksNginxFqdn string = aksNginx.outputs.controlPlaneFqdn

@description('Application Gateway for Containers name')
output agcName string = agc.outputs.name

@description('Log Analytics Workspace ID')
output logAnalyticsWorkspaceId string = logAnalytics.id

@description('VNet name')
output vnetName string = network.outputs.vnetName

@description('Commands to get cluster credentials')
output getCredentialsCommands object = {
  agcCluster: 'az aks get-credentials --resource-group ${resourceGroup().name} --name ${aksAgcName}'
  nginxCluster: 'az aks get-credentials --resource-group ${resourceGroup().name} --name ${aksNginxName}'
}
