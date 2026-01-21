// ============================================================================
// Application Gateway v2 Module - For NGINX Cluster HTTPS Frontend
// ============================================================================
// Deploys Azure Application Gateway v2 with:
// - HTTPS frontend listener with TLS termination
// - Backend pool pointing to NGINX ingress service
// - HTTP backend to preserve HTTP internally
// ============================================================================

@description('Azure region for deployment')
param location string

@description('Application Gateway name')
param name string

@description('Subnet resource ID for Application Gateway')
param subnetId string

@description('Public IP address resource ID')
param publicIpId string

@description('Backend FQDN or IP for NGINX ingress')
param backendAddress string = ''

@description('SSL certificate data (base64 encoded PFX)')
@secure()
param sslCertificateData string

@description('SSL certificate password')
@secure()
param sslCertificatePassword string

@description('Enable WAF on Application Gateway')
param enableWaf bool = true

@description('Resource tags')
param tags object

// ============================================================================
// Resources
// ============================================================================

// WAF Policy for Application Gateway
resource wafPolicy 'Microsoft.Network/ApplicationGatewayWebApplicationFirewallPolicies@2024-05-01' = if (enableWaf) {
  name: '${name}-waf-policy'
  location: location
  tags: tags
  properties: {
    policySettings: {
      mode: 'Detection'
      state: 'Enabled'
      requestBodyCheck: true
      maxRequestBodySizeInKb: 128
      fileUploadLimitInMb: 100
    }
    managedRules: {
      managedRuleSets: [
        {
          ruleSetType: 'OWASP'
          ruleSetVersion: '3.2'
        }
      ]
    }
  }
}

// Application Gateway v2 (with optional WAF)
resource appGateway 'Microsoft.Network/applicationGateways@2024-05-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    sku: {
      name: enableWaf ? 'WAF_v2' : 'Standard_v2'
      tier: enableWaf ? 'WAF_v2' : 'Standard_v2'
    }
    firewallPolicy: enableWaf ? {
      id: wafPolicy.id
    } : null
    autoscaleConfiguration: {
      minCapacity: 1
      maxCapacity: 3
    }
    gatewayIPConfigurations: [
      {
        name: 'appGatewayIpConfig'
        properties: {
          subnet: {
            id: subnetId
          }
        }
      }
    ]
    frontendIPConfigurations: [
      {
        name: 'appGatewayFrontendIP'
        properties: {
          publicIPAddress: {
            id: publicIpId
          }
        }
      }
    ]
    frontendPorts: [
      {
        name: 'https-port'
        properties: {
          port: 443
        }
      }
      {
        name: 'http-port'
        properties: {
          port: 80
        }
      }
    ]
    sslCertificates: [
      {
        name: 'appGatewaySslCert'
        properties: {
          data: sslCertificateData
          password: sslCertificatePassword
        }
      }
    ]
    backendAddressPools: [
      {
        name: 'nginxBackendPool'
        properties: {
          backendAddresses: empty(backendAddress) ? [] : [
            {
              ipAddress: backendAddress
            }
          ]
        }
      }
    ]
    backendHttpSettingsCollection: [
      {
        name: 'httpSettings'
        properties: {
          port: 80
          protocol: 'Http'
          cookieBasedAffinity: 'Disabled'
          requestTimeout: 30
          pickHostNameFromBackendAddress: false
          probe: {
            id: resourceId('Microsoft.Network/applicationGateways/probes', name, 'healthProbe')
          }
        }
      }
    ]
    httpListeners: [
      {
        name: 'httpsListener'
        properties: {
          frontendIPConfiguration: {
            id: resourceId('Microsoft.Network/applicationGateways/frontendIPConfigurations', name, 'appGatewayFrontendIP')
          }
          frontendPort: {
            id: resourceId('Microsoft.Network/applicationGateways/frontendPorts', name, 'https-port')
          }
          protocol: 'Https'
          sslCertificate: {
            id: resourceId('Microsoft.Network/applicationGateways/sslCertificates', name, 'appGatewaySslCert')
          }
        }
      }
      {
        name: 'httpListener'
        properties: {
          frontendIPConfiguration: {
            id: resourceId('Microsoft.Network/applicationGateways/frontendIPConfigurations', name, 'appGatewayFrontendIP')
          }
          frontendPort: {
            id: resourceId('Microsoft.Network/applicationGateways/frontendPorts', name, 'http-port')
          }
          protocol: 'Http'
        }
      }
    ]
    probes: [
      {
        name: 'healthProbe'
        properties: {
          protocol: 'Http'
          path: '/health'
          interval: 30
          timeout: 30
          unhealthyThreshold: 3
          pickHostNameFromBackendHttpSettings: false
          host: '127.0.0.1'
          match: {
            statusCodes: [
              '200-399'
            ]
          }
        }
      }
    ]
    requestRoutingRules: [
      {
        name: 'httpsRule'
        properties: {
          priority: 100
          ruleType: 'Basic'
          httpListener: {
            id: resourceId('Microsoft.Network/applicationGateways/httpListeners', name, 'httpsListener')
          }
          backendAddressPool: {
            id: resourceId('Microsoft.Network/applicationGateways/backendAddressPools', name, 'nginxBackendPool')
          }
          backendHttpSettings: {
            id: resourceId('Microsoft.Network/applicationGateways/backendHttpSettingsCollection', name, 'httpSettings')
          }
        }
      }
      {
        name: 'httpRedirectRule'
        properties: {
          priority: 200
          ruleType: 'Basic'
          httpListener: {
            id: resourceId('Microsoft.Network/applicationGateways/httpListeners', name, 'httpListener')
          }
          redirectConfiguration: {
            id: resourceId('Microsoft.Network/applicationGateways/redirectConfigurations', name, 'httpToHttpsRedirect')
          }
        }
      }
    ]
    redirectConfigurations: [
      {
        name: 'httpToHttpsRedirect'
        properties: {
          redirectType: 'Permanent'
          targetListener: {
            id: resourceId('Microsoft.Network/applicationGateways/httpListeners', name, 'httpsListener')
          }
          includePath: true
          includeQueryString: true
        }
      }
    ]
  }
}

// ============================================================================
// Outputs
// ============================================================================

@description('Application Gateway resource ID')
output id string = appGateway.id

@description('Application Gateway name')
output name string = appGateway.name

@description('Backend pool ID for NGINX')
output backendPoolId string = resourceId('Microsoft.Network/applicationGateways/backendAddressPools', name, 'nginxBackendPool')
