// ============================================================================
// AKS Cluster Module - Managed NGINX Ingress Controller
// ============================================================================
// Deploys an AKS cluster with the managed NGINX ingress controller add-on
// (Web Application Routing). Uses Azure CNI Powered by Cilium for networking.
// Configuration is kept similar to the AGC cluster for fair comparison.
// ============================================================================

@description('Azure region for deployment')
param location string

@description('AKS cluster name')
param clusterName string

@description('VM size for nodes')
param nodeVmSize string

@description('Number of nodes')
param nodeCount int

@description('Subnet resource ID for the cluster')
param subnetId string

@description('Log Analytics workspace resource ID')
param logAnalyticsWorkspaceId string

@description('Resource tags')
param tags object

// ============================================================================
// Variables
// ============================================================================

var nodePoolName = 'systempool'

// ============================================================================
// Resources
// ============================================================================

// User Assigned Managed Identity for AKS
resource aksIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = {
  name: '${clusterName}-identity'
  location: location
  tags: tags
}

// AKS Cluster with Azure CNI Powered by Cilium and Managed NGINX
resource aksCluster 'Microsoft.ContainerService/managedClusters@2024-09-02-preview' = {
  name: clusterName
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${aksIdentity.id}': {}
    }
  }
  sku: {
    name: 'Base'
    tier: 'Standard'
  }
  properties: {
    dnsPrefix: clusterName
    
    // Enable Azure RBAC for Kubernetes authorization
    aadProfile: {
      enableAzureRBAC: true
      managed: true
    }
    
    // Disable local accounts for security
    disableLocalAccounts: false // Set to true in production
    
    // Network profile - Azure CNI Powered by Cilium (same as AGC cluster)
    networkProfile: {
      networkPlugin: 'azure'
      networkPluginMode: 'overlay'
      networkDataplane: 'cilium'  // Azure CNI Powered by Cilium
      networkPolicy: 'cilium'
      serviceCidr: '10.101.0.0/16'
      dnsServiceIP: '10.101.0.10'
      loadBalancerSku: 'standard'
      outboundType: 'loadBalancer'
    }
    
    // Agent pool profiles (same configuration as AGC cluster)
    agentPoolProfiles: [
      {
        name: nodePoolName
        count: nodeCount
        vmSize: nodeVmSize
        osType: 'Linux'
        osSKU: 'AzureLinux'
        mode: 'System'
        type: 'VirtualMachineScaleSets'
        enableAutoScaling: false
        maxPods: 50
        vnetSubnetID: subnetId
        enableNodePublicIP: false
      }
    ]
    
    // Add-ons including Web Application Routing (managed NGINX)
    addonProfiles: {
      // Azure Monitor for containers
      omsagent: {
        enabled: true
        config: {
          logAnalyticsWorkspaceResourceID: logAnalyticsWorkspaceId
          useAADAuth: 'true'
        }
      }
      // Azure Policy
      azurepolicy: {
        enabled: true
        config: {
          version: 'v2'
        }
      }
    }
    
    // Web Application Routing - Managed NGINX Ingress Controller
    ingressProfile: {
      webAppRouting: {
        enabled: true
      }
    }
    
    // OIDC issuer for workload identity
    oidcIssuerProfile: {
      enabled: true
    }
    
    // Enable workload identity
    securityProfile: {
      workloadIdentity: {
        enabled: true
      }
    }
    
    // Storage profile
    storageProfile: {
      diskCSIDriver: {
        enabled: true
      }
      fileCSIDriver: {
        enabled: true
      }
      snapshotController: {
        enabled: true
      }
    }
    
    // Auto upgrade settings
    autoUpgradeProfile: {
      upgradeChannel: 'stable'
      nodeOSUpgradeChannel: 'NodeImage'
    }
  }
}

// Role assignment for the managed identity on the subnet
resource subnetRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subnetId, aksIdentity.id, 'Network Contributor')
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4d97b98b-1d4f-4787-a291-c67834d212e7') // Network Contributor
    principalId: aksIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// ============================================================================
// Outputs
// ============================================================================

@description('AKS cluster resource ID')
output clusterId string = aksCluster.id

@description('AKS cluster name')
output clusterName string = aksCluster.name

@description('AKS control plane FQDN')
output controlPlaneFqdn string = aksCluster.properties.fqdn

@description('AKS OIDC issuer URL')
output oidcIssuerUrl string = aksCluster.properties.oidcIssuerProfile.issuerURL

@description('AKS kubelet identity object ID')
output kubeletIdentityObjectId string = aksCluster.properties.identityProfile.kubeletidentity.objectId

@description('AKS managed identity principal ID')
output identityPrincipalId string = aksIdentity.properties.principalId

@description('AKS managed identity client ID')
output identityClientId string = aksIdentity.properties.clientId

@description('Web Application Routing (NGINX) ingress class name')
output ingressClassName string = 'webapprouting.kubernetes.azure.com'
