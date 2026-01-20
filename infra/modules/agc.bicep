// ============================================================================
// Application Gateway for Containers (Traffic Controller) Module
// ============================================================================
// Deploys the Application Gateway for Containers (AGC) Traffic Controller
// with a frontend and association to the designated subnet.
// The ALB Controller in AKS will manage the actual Gateway configuration.
// ============================================================================

@description('Azure region for deployment')
param location string

@description('Application Gateway for Containers name')
param name string

@description('Subnet resource ID for AGC association')
param subnetId string

@description('Resource tags')
param tags object

// ============================================================================
// Resources
// ============================================================================

// Application Gateway for Containers (Traffic Controller)
resource trafficController 'Microsoft.ServiceNetworking/trafficControllers@2023-11-01' = {
  name: name
  location: location
  tags: tags
  properties: {}
}

// Frontend for the Traffic Controller
resource frontend 'Microsoft.ServiceNetworking/trafficControllers/frontends@2023-11-01' = {
  parent: trafficController
  name: 'frontend-default'
  location: location
  properties: {}
}

// Association with the subnet
resource association 'Microsoft.ServiceNetworking/trafficControllers/associations@2023-11-01' = {
  parent: trafficController
  name: 'association-default'
  location: location
  properties: {
    associationType: 'subnets'
    subnet: {
      id: subnetId
    }
  }
}

// ============================================================================
// Outputs
// ============================================================================

@description('Traffic Controller resource ID')
output id string = trafficController.id

@description('Traffic Controller name')
output name string = trafficController.name

@description('Frontend resource ID')
output frontendId string = frontend.id

@description('Frontend name')
output frontendName string = frontend.name

@description('Association resource ID')
output associationId string = association.id

@description('Configuration endpoints')
output configurationEndpoints array = trafficController.properties.configurationEndpoints
