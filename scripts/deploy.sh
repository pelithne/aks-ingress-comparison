#!/bin/bash
# ============================================================================
# Deployment Script for AKS Ingress Comparison Infrastructure
# ============================================================================
# This script deploys all infrastructure and configures the AKS clusters
# for ingress performance testing.
# ============================================================================

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
INFRA_DIR="${ROOT_DIR}/infra"
K8S_DIR="${ROOT_DIR}/k8s"

# Default values
RESOURCE_GROUP="${RESOURCE_GROUP:-rg-aks-ingress-compare-10}"
LOCATION="${LOCATION:-northeurope}"
BASE_NAME="${BASE_NAME:-akstest}"
DEPLOYMENT_NAME="aks-ingress-comparison"
CERT_DIR="${CERT_DIR:-${ROOT_DIR}/.certs}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_header() {
    echo -e "\n${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}\n"
}

print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check prerequisites
check_prerequisites() {
    print_header "Checking Prerequisites"
    
    local missing_tools=()
    
    for tool in az kubectl helm jq openssl; do
        if ! command -v "$tool" &> /dev/null; then
            missing_tools+=("$tool")
        else
            print_info "$tool is installed"
        fi
    done
    
    if [ ${#missing_tools[@]} -ne 0 ]; then
        print_error "Missing required tools: ${missing_tools[*]}"
        exit 1
    fi
    
    # Check Azure CLI login
    if ! az account show &> /dev/null; then
        print_error "Not logged in to Azure. Please run 'az login' first."
        exit 1
    fi
    
    print_info "Azure CLI is authenticated"
    print_info "Current subscription: $(az account show --query name -o tsv)"
}

# Generate self-signed TLS certificate
generate_tls_certificate() {
    print_header "Generating TLS Certificate"
    
    mkdir -p "$CERT_DIR"
    
    local CERT_KEY="${CERT_DIR}/tls.key"
    local CERT_CRT="${CERT_DIR}/tls.crt"
    local CERT_PFX="${CERT_DIR}/tls.pfx"
    local CERT_PASSWORD="AksIngressTest123!"
    
    if [[ -f "$CERT_PFX" ]]; then
        print_info "Certificate already exists, skipping generation"
    else
        print_info "Generating self-signed certificate..."
        
        # Generate private key and certificate
        openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
            -keyout "$CERT_KEY" \
            -out "$CERT_CRT" \
            -subj "/CN=*.northeurope.cloudapp.azure.com/O=AKS-Ingress-Test" \
            -addext "subjectAltName=DNS:*.northeurope.cloudapp.azure.com,DNS:*.alb.azure.com,DNS:*.fz05.alb.azure.com" \
            2>/dev/null
        
        # Convert to PFX for Application Gateway
        openssl pkcs12 -export \
            -out "$CERT_PFX" \
            -inkey "$CERT_KEY" \
            -in "$CERT_CRT" \
            -password "pass:${CERT_PASSWORD}" \
            2>/dev/null
        
        print_info "Certificate generated: $CERT_PFX"
    fi
    
    # Export for Bicep deployment
    SSL_CERT_DATA=$(base64 -w0 "$CERT_PFX")
    SSL_CERT_PASSWORD="$CERT_PASSWORD"
    
    # Store for later use (K8s secret)
    export TLS_KEY_FILE="$CERT_KEY"
    export TLS_CRT_FILE="$CERT_CRT"
}

# Deploy infrastructure with Bicep
deploy_infrastructure() {
    print_header "Deploying Infrastructure with Bicep"
    
    # Check if deployment info already exists and resources are deployed
    if [[ -f "${ROOT_DIR}/.deployment-info.json" ]]; then
        load_deployment_info
        if az aks show --resource-group "$RESOURCE_GROUP" --name "$AGC_CLUSTER_NAME" &>/dev/null; then
            print_info "Infrastructure already deployed, skipping Bicep deployment"
            return 0
        fi
    fi
    
    # Create resource group if it doesn't exist
    if ! az group show --name "$RESOURCE_GROUP" &> /dev/null; then
        print_info "Creating resource group: $RESOURCE_GROUP"
        az group create --name "$RESOURCE_GROUP" --location "$LOCATION" --output none
    else
        print_info "Resource group already exists: $RESOURCE_GROUP"
    fi
    
    # Deploy Bicep template
    print_info "Deploying Bicep template..."
    
    DEPLOYMENT_OUTPUT=$(az deployment group create \
        --name "$DEPLOYMENT_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --template-file "${INFRA_DIR}/main.bicep" \
        --parameters baseName="$BASE_NAME" location="$LOCATION" \
        --parameters sslCertificateData="$SSL_CERT_DATA" sslCertificatePassword="$SSL_CERT_PASSWORD" \
        --output json)
    
    # Extract outputs
    AGC_CLUSTER_NAME=$(echo "$DEPLOYMENT_OUTPUT" | jq -r '.properties.outputs.aksAgcClusterName.value')
    NGINX_CLUSTER_NAME=$(echo "$DEPLOYMENT_OUTPUT" | jq -r '.properties.outputs.aksNginxClusterName.value')
    AGC_CLUSTER_FQDN=$(echo "$DEPLOYMENT_OUTPUT" | jq -r '.properties.outputs.aksAgcFqdn.value')
    NGINX_CLUSTER_FQDN=$(echo "$DEPLOYMENT_OUTPUT" | jq -r '.properties.outputs.aksNginxFqdn.value')
    AGC_NAME=$(echo "$DEPLOYMENT_OUTPUT" | jq -r '.properties.outputs.agcName.value')
    VNET_NAME=$(echo "$DEPLOYMENT_OUTPUT" | jq -r '.properties.outputs.vnetName.value')
    APPGW_NAME=$(echo "$DEPLOYMENT_OUTPUT" | jq -r '.properties.outputs.appGwName.value // empty')
    APPGW_FQDN=$(echo "$DEPLOYMENT_OUTPUT" | jq -r '.properties.outputs.appGwFqdn.value // empty')
    AGC_WAF_POLICY_ID=$(echo "$DEPLOYMENT_OUTPUT" | jq -r '.properties.outputs.agcWafPolicyId.value // empty')
    
    print_info "Infrastructure deployment complete!"
    print_info "AGC Cluster: $AGC_CLUSTER_NAME"
    print_info "NGINX Cluster: $NGINX_CLUSTER_NAME"
    print_info "Application Gateway: $APPGW_NAME"
    print_info "WAF enabled on both gateways"
    
    # Save deployment info
    cat > "${ROOT_DIR}/.deployment-info.json" << EOF
{
    "resourceGroup": "$RESOURCE_GROUP",
    "location": "$LOCATION",
    "agcClusterName": "$AGC_CLUSTER_NAME",
    "nginxClusterName": "$NGINX_CLUSTER_NAME",
    "agcName": "$AGC_NAME",
    "vnetName": "$VNET_NAME",
    "appGwName": "$APPGW_NAME",
    "appGwFqdn": "$APPGW_FQDN",
    "agcWafPolicyId": "$AGC_WAF_POLICY_ID",
    "deploymentName": "$DEPLOYMENT_NAME",
    "timestamp": "$(date -Iseconds)"
}
EOF
}

# Load deployment info from file
load_deployment_info() {
    if [[ -f "${ROOT_DIR}/.deployment-info.json" ]]; then
        AGC_CLUSTER_NAME=$(jq -r '.agcClusterName // empty' "${ROOT_DIR}/.deployment-info.json")
        NGINX_CLUSTER_NAME=$(jq -r '.nginxClusterName // empty' "${ROOT_DIR}/.deployment-info.json")
        AGC_NAME=$(jq -r '.agcName // empty' "${ROOT_DIR}/.deployment-info.json")
        VNET_NAME=$(jq -r '.vnetName // empty' "${ROOT_DIR}/.deployment-info.json")
        APPGW_NAME=$(jq -r '.appGwName // empty' "${ROOT_DIR}/.deployment-info.json")
        APPGW_FQDN=$(jq -r '.appGwFqdn // empty' "${ROOT_DIR}/.deployment-info.json")
    fi
    
    # If VNET_NAME is empty, query Azure for VNet in the resource group
    if [[ -z "$VNET_NAME" || "$VNET_NAME" == "null" ]]; then
        print_info "Looking up VNet name from Azure..."
        VNET_NAME=$(az network vnet list --resource-group "$RESOURCE_GROUP" --query "[0].name" -o tsv 2>/dev/null || echo "")
    fi
}

# Assign Azure RBAC roles for AKS cluster access
assign_cluster_roles() {
    print_header "Assigning Azure RBAC Roles for Cluster Access"
    
    load_deployment_info
    
    # Get current user's object ID
    CURRENT_USER_ID=$(az ad signed-in-user show --query id -o tsv)
    
    print_info "Current user ID: $CURRENT_USER_ID"
    
    # Get AGC cluster resource ID
    AGC_CLUSTER_ID=$(az aks show --resource-group "$RESOURCE_GROUP" --name "$AGC_CLUSTER_NAME" --query id -o tsv)
    
    # Get NGINX cluster resource ID
    NGINX_CLUSTER_ID=$(az aks show --resource-group "$RESOURCE_GROUP" --name "$NGINX_CLUSTER_NAME" --query id -o tsv)
    
    # Assign Azure Kubernetes Service RBAC Cluster Admin role
    print_info "Assigning Cluster Admin role for AGC cluster..."
    az role assignment create \
        --assignee "$CURRENT_USER_ID" \
        --role "Azure Kubernetes Service RBAC Cluster Admin" \
        --scope "$AGC_CLUSTER_ID" \
        --output none 2>/dev/null || print_info "Role may already be assigned for AGC cluster"
    
    print_info "Assigning Cluster Admin role for NGINX cluster..."
    az role assignment create \
        --assignee "$CURRENT_USER_ID" \
        --role "Azure Kubernetes Service RBAC Cluster Admin" \
        --scope "$NGINX_CLUSTER_ID" \
        --output none 2>/dev/null || print_info "Role may already be assigned for NGINX cluster"
    
    # Only wait if we actually created new assignments
    if [[ $? -eq 0 ]]; then
        print_info "Waiting for role assignments to propagate..."
        sleep 10
    fi
}

# Get AKS credentials
get_cluster_credentials() {
    print_header "Getting AKS Cluster Credentials"
    
    print_info "Getting credentials for AGC cluster..."
    az aks get-credentials \
        --resource-group "$RESOURCE_GROUP" \
        --name "$AGC_CLUSTER_NAME" \
        --overwrite-existing \
        --context "agc-cluster"
    
    print_info "Getting credentials for NGINX cluster..."
    az aks get-credentials \
        --resource-group "$RESOURCE_GROUP" \
        --name "$NGINX_CLUSTER_NAME" \
        --overwrite-existing \
        --context "nginx-cluster"
}

# Install ALB Controller on AGC cluster
install_alb_controller() {
    print_header "Installing ALB Controller on AGC Cluster"
    
    kubectl config use-context "agc-cluster"
    
    # Get cluster info for ALB Controller
    AGC_CLUSTER_INFO=$(az aks show \
        --resource-group "$RESOURCE_GROUP" \
        --name "$AGC_CLUSTER_NAME" \
        --output json)
    
    OIDC_ISSUER_URL=$(echo "$AGC_CLUSTER_INFO" | jq -r '.oidcIssuerProfile.issuerUrl')
    MC_RESOURCE_GROUP=$(echo "$AGC_CLUSTER_INFO" | jq -r '.nodeResourceGroup')
    MC_RESOURCE_GROUP_ID=$(az group show --name "$MC_RESOURCE_GROUP" --query id -o tsv)
    
    # Create the azure-alb-identity managed identity (required name per Microsoft docs)
    IDENTITY_RESOURCE_NAME="azure-alb-identity"
    
    # Check if identity already exists
    if az identity show --resource-group "$RESOURCE_GROUP" --name "$IDENTITY_RESOURCE_NAME" &>/dev/null; then
        print_info "Managed identity already exists, skipping creation"
        IDENTITY_EXISTED=true
    else
        print_info "Creating managed identity for ALB Controller..."
        az identity create \
            --resource-group "$RESOURCE_GROUP" \
            --name "$IDENTITY_RESOURCE_NAME" \
            --output none
        IDENTITY_EXISTED=false
    fi
    
    PRINCIPAL_ID=$(az identity show \
        --resource-group "$RESOURCE_GROUP" \
        --name "$IDENTITY_RESOURCE_NAME" \
        --query principalId -o tsv)
    
    # Only wait if we just created the identity
    if [[ "$IDENTITY_EXISTED" == "false" ]]; then
        print_info "Waiting 60 seconds for identity replication..."
        sleep 60
    fi
    
    # Assign Reader role to the MC resource group
    print_info "Assigning Reader role to managed cluster resource group..."
    az role assignment create \
        --assignee-object-id "$PRINCIPAL_ID" \
        --assignee-principal-type ServicePrincipal \
        --scope "$MC_RESOURCE_GROUP_ID" \
        --role "acdd72a7-3385-48ef-bd42-f606fba81ae7" \
        --output none 2>/dev/null || print_info "Role assignment may already exist"
    
    # Create federated credential for the ALB Controller service account
    print_info "Creating federated identity for ALB Controller..."
    az identity federated-credential create \
        --name "azure-alb-identity" \
        --identity-name "$IDENTITY_RESOURCE_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --issuer "$OIDC_ISSUER_URL" \
        --subject "system:serviceaccount:azure-alb-system:alb-controller-sa" \
        --output none 2>/dev/null || print_info "Federated credential may already exist"
    
    # Get the AGC resource and subnet for role assignments
    load_deployment_info
    AGC_ID=$(az network alb list --resource-group "$RESOURCE_GROUP" --query "[0].id" -o tsv)
    SUBNET_ID=$(az network vnet subnet show --resource-group "$RESOURCE_GROUP" --vnet-name "$VNET_NAME" --name "snet-agc" --query id -o tsv)
    
    # Assign AppGw for Containers Configuration Manager role on AGC
    print_info "Assigning roles for ALB Controller to manage AGC..."
    az role assignment create \
        --assignee-object-id "$PRINCIPAL_ID" \
        --assignee-principal-type ServicePrincipal \
        --role "AppGw for Containers Configuration Manager" \
        --scope "$AGC_ID" \
        --output none 2>/dev/null || print_info "AGC role may already be assigned"
    
    # Assign Network Contributor role on AGC subnet
    az role assignment create \
        --assignee-object-id "$PRINCIPAL_ID" \
        --assignee-principal-type ServicePrincipal \
        --role "Network Contributor" \
        --scope "$SUBNET_ID" \
        --output none 2>/dev/null || print_info "Subnet role may already be assigned"
    
    # Get the identity client ID
    IDENTITY_CLIENT_ID=$(az identity show \
        --resource-group "$RESOURCE_GROUP" \
        --name "$IDENTITY_RESOURCE_NAME" \
        --query clientId -o tsv)
    
    # Install ALB Controller with Helm from OCI registry
    print_info "Installing ALB Controller with Helm..."
    helm upgrade --install alb-controller oci://mcr.microsoft.com/application-lb/charts/alb-controller \
        --version 1.8.12 \
        --namespace azure-alb-system \
        --create-namespace \
        --set albController.namespace=azure-alb-system \
        --set albController.podIdentity.clientID="$IDENTITY_CLIENT_ID" \
        --wait
    
    print_info "ALB Controller installed successfully"
}

# Deploy applications to NGINX cluster
deploy_nginx_cluster() {
    print_header "Deploying Application to NGINX Cluster"
    
    load_deployment_info
    
    kubectl config use-context "nginx-cluster"
    
    # Deploy the common application
    print_info "Deploying demo application..."
    kubectl apply -f "${K8S_DIR}/common/demo-app.yaml"
    
    # Wait for deployment
    print_info "Waiting for demo application to be ready..."
    kubectl wait --for=condition=available --timeout=120s deployment/demo-app -n demo-app
    
    # Deploy NGINX ingress
    print_info "Deploying NGINX ingress..."
    kubectl apply -f "${K8S_DIR}/nginx-cluster/ingress.yaml"
    
    # Wait for ingress to get an address
    print_info "Waiting for ingress to be ready..."
    for i in {1..60}; do
        NGINX_INGRESS_IP=$(kubectl get ingress demo-app-ingress -n demo-app -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
        if [[ -n "$NGINX_INGRESS_IP" ]]; then
            print_info "NGINX Ingress IP: $NGINX_INGRESS_IP"
            break
        fi
        echo -n "."
        sleep 5
    done
    echo ""
    
    if [[ -z "$NGINX_INGRESS_IP" ]]; then
        print_warn "Could not get NGINX ingress IP. Checking ingress status..."
        kubectl describe ingress demo-app-ingress -n demo-app
    fi
    
    # Update Application Gateway backend pool with NGINX ingress IP
    if [[ -n "$NGINX_INGRESS_IP" && -n "${APPGW_NAME:-}" ]]; then
        print_info "Updating Application Gateway backend pool with NGINX ingress IP..."
        az network application-gateway address-pool update \
            --gateway-name "$APPGW_NAME" \
            --resource-group "$RESOURCE_GROUP" \
            --name "nginxBackendPool" \
            --servers "$NGINX_INGRESS_IP" \
            --output none
        print_info "Application Gateway backend updated with NGINX IP: $NGINX_INGRESS_IP"
        
        # Get Application Gateway FQDN
        APPGW_FQDN=$(az network public-ip show \
            --resource-group "$RESOURCE_GROUP" \
            --name "${APPGW_NAME}-pip" \
            --query 'dnsSettings.fqdn' -o tsv 2>/dev/null || echo "")
        
        if [[ -n "$APPGW_FQDN" ]]; then
            print_info "NGINX (via App Gateway) HTTPS: https://$APPGW_FQDN"
        fi
    fi
}

# Deploy WAF for AGC using SecurityPolicy and WebApplicationFirewallPolicy CRD
deploy_agc_waf() {
    print_header "Deploying WAF for AGC"
    
    kubectl config use-context "agc-cluster"
    
    # Get the WAF Policy ID (created by Bicep)
    AGC_WAF_POLICY_ID=$(az network application-gateway waf-policy show \
        --name "${AGC_NAME}-waf-policy" \
        --resource-group "$RESOURCE_GROUP" \
        --query id -o tsv 2>/dev/null || echo "")
    
    if [[ -z "$AGC_WAF_POLICY_ID" ]]; then
        print_warn "AGC WAF Policy not found. Skipping WAF deployment."
        return 0
    fi
    
    print_info "WAF Policy ID: $AGC_WAF_POLICY_ID"
    
    # Create SecurityPolicy on AGC via REST API
    print_info "Creating SecurityPolicy on AGC..."
    SUB_ID=$(az account show --query id -o tsv)
    AGC_RESOURCE_ID="/subscriptions/${SUB_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.ServiceNetworking/trafficControllers/${AGC_NAME}"
    
    az rest --method PUT \
        --uri "https://management.azure.com${AGC_RESOURCE_ID}/securityPolicies/agc-security-policy?api-version=2025-01-01" \
        --body "{
            \"location\": \"${LOCATION}\",
            \"properties\": {
                \"wafPolicy\": {
                    \"id\": \"${AGC_WAF_POLICY_ID}\"
                }
            }
        }" --output none 2>/dev/null || print_warn "SecurityPolicy may already exist"
    
    # Wait for SecurityPolicy to be provisioned
    print_info "Waiting for SecurityPolicy to be provisioned..."
    for i in {1..12}; do
        STATUS=$(az rest --method GET \
            --uri "https://management.azure.com${AGC_RESOURCE_ID}/securityPolicies/agc-security-policy?api-version=2025-01-01" \
            --query 'properties.provisioningState' -o tsv 2>/dev/null || echo "")
        if [[ "$STATUS" == "Succeeded" ]]; then
            print_info "SecurityPolicy provisioned successfully"
            break
        fi
        echo -n "."
        sleep 5
    done
    echo ""
    
    # Create WebApplicationFirewallPolicy CRD
    print_info "Creating WebApplicationFirewallPolicy CRD..."
    cat <<EOF | kubectl apply -f -
apiVersion: alb.networking.azure.io/v1
kind: WebApplicationFirewallPolicy
metadata:
  name: agc-security-policy
  namespace: demo-app
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: Gateway
    name: demo-app-gateway
  webApplicationFirewall:
    id: "${AGC_WAF_POLICY_ID}"
EOF
    
    # Wait for WAF policy to be deployed
    print_info "Waiting for WAF policy to be deployed..."
    for i in {1..12}; do
        DEPLOYED=$(kubectl get webapplicationfirewallpolicy agc-security-policy -n demo-app -o jsonpath='{.status.deployment}' 2>/dev/null || echo "")
        if [[ "$DEPLOYED" == "True" ]]; then
            print_info "WAF policy deployed successfully"
            break
        fi
        echo -n "."
        sleep 5
    done
    echo ""
}

# Deploy applications to AGC cluster
deploy_agc_cluster() {
    print_header "Deploying Application to AGC Cluster"
    
    load_deployment_info
    
    kubectl config use-context "agc-cluster"
    
    # Get AGC subnet ID for the ApplicationLoadBalancer
    AGC_SUBNET_ID=$(az network vnet subnet show \
        --resource-group "$RESOURCE_GROUP" \
        --vnet-name "$VNET_NAME" \
        --name "snet-agc" \
        --query id -o tsv)
    
    # Get AGC resource ID
    AGC_RESOURCE_ID=$(az network alb show \
        --resource-group "$RESOURCE_GROUP" \
        --name "$AGC_NAME" \
        --query id -o tsv)
    
    # Deploy the common application
    print_info "Deploying demo application..."
    kubectl apply -f "${K8S_DIR}/common/demo-app.yaml"
    
    # Wait for deployment
    print_info "Waiting for demo application to be ready..."
    kubectl wait --for=condition=available --timeout=120s deployment/demo-app -n demo-app
    
    # Create TLS secret for AGC HTTPS termination
    print_info "Creating TLS secret for AGC..."
    kubectl create secret tls agc-tls-secret \
        --cert="${TLS_CRT_FILE}" \
        --key="${TLS_KEY_FILE}" \
        -n demo-app \
        --dry-run=client -o yaml | kubectl apply -f -
    
    # Deploy ALB controller config with substituted values
    print_info "Deploying ApplicationLoadBalancer configuration..."
    sed "s|\${AGC_SUBNET_ID}|${AGC_SUBNET_ID}|g" "${K8S_DIR}/agc-cluster/alb-controller-config.yaml" | kubectl apply -f -
    
    # Deploy Gateway API resources with substituted values
    print_info "Deploying Gateway API resources..."
    sed "s|\${ALB_ID}|${AGC_RESOURCE_ID}|g" "${K8S_DIR}/agc-cluster/gateway.yaml" | kubectl apply -f -
    
    # Wait for Gateway to be ready
    print_info "Waiting for Gateway to be ready..."
    for i in {1..60}; do
        GATEWAY_STATUS=$(kubectl get gateway demo-app-gateway -n demo-app -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null || echo "")
        if [[ "$GATEWAY_STATUS" == "True" ]]; then
            print_info "Gateway is accepted"
            break
        fi
        echo -n "."
        sleep 5
    done
    echo ""
    
    # Get AGC frontend IP/hostname
    print_info "Getting AGC frontend address..."
    AGC_FRONTEND=$(kubectl get gateway demo-app-gateway -n demo-app -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || echo "")
    
    if [[ -n "$AGC_FRONTEND" ]]; then
        print_info "AGC Frontend: https://$AGC_FRONTEND"
    else
        print_warn "Could not get AGC frontend address. Checking Gateway status..."
        kubectl describe gateway demo-app-gateway -n demo-app
    fi
    
    # Deploy WAF for AGC
    deploy_agc_waf
}

# Print deployment summary
print_summary() {
    print_header "Deployment Summary"
    
    load_deployment_info
    
    # Get endpoints
    kubectl config use-context "nginx-cluster"
    NGINX_INGRESS_IP=$(kubectl get ingress demo-app-ingress -n demo-app -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "N/A")
    
    kubectl config use-context "agc-cluster"
    AGC_FRONTEND=$(kubectl get gateway demo-app-gateway -n demo-app -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || echo "N/A")
    
    echo -e "${GREEN}Resource Group:${NC} $RESOURCE_GROUP"
    echo -e "${GREEN}Location:${NC} $LOCATION"
    echo ""
    echo -e "${GREEN}AGC Cluster:${NC} $AGC_CLUSTER_NAME"
    echo -e "${GREEN}AGC Endpoint (HTTPS):${NC} https://${AGC_FRONTEND}"
    echo ""
    echo -e "${GREEN}NGINX Cluster:${NC} $NGINX_CLUSTER_NAME"
    echo -e "${GREEN}NGINX Backend IP:${NC} ${NGINX_INGRESS_IP}"
    echo -e "${GREEN}NGINX Endpoint (HTTPS via AppGW):${NC} https://${APPGW_FQDN}"
    echo ""
    
    # Save endpoints
    cat > "${ROOT_DIR}/.endpoints.json" << EOF
{
    "agc": {
        "clusterName": "$AGC_CLUSTER_NAME",
        "endpoint": "https://${AGC_FRONTEND}"
    },
    "nginx": {
        "clusterName": "$NGINX_CLUSTER_NAME",
        "backendIp": "${NGINX_INGRESS_IP}",
        "endpoint": "https://${APPGW_FQDN}"
    }
}
EOF

    echo -e "${YELLOW}Note: Using self-signed certificates. Add -k flag to curl for testing.${NC}"
    echo ""
    echo -e "${GREEN}To run performance tests:${NC}"
    echo "  ./scripts/test-performance.sh -a https://${AGC_FRONTEND} -n https://${APPGW_FQDN}"
    echo ""
    echo -e "${GREEN}To access clusters:${NC}"
    echo "  kubectl config use-context agc-cluster"
    echo "  kubectl config use-context nginx-cluster"
}

# Cleanup function
cleanup() {
    print_header "Cleaning Up Resources"
    
    read -p "Are you sure you want to delete the resource group $RESOURCE_GROUP? (y/N) " -n 1 -r
    echo ""
    
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        print_info "Deleting resource group..."
        az group delete --name "$RESOURCE_GROUP" --yes --no-wait
        print_info "Resource group deletion initiated (running in background)"
    else
        print_info "Cleanup cancelled"
    fi
}

# Usage
usage() {
    cat << EOF
Usage: $0 <command> [options]

Commands:
  deploy      Deploy the complete infrastructure and applications
  cleanup     Delete all resources
  status      Show deployment status
  test        Run performance tests

Options:
  -g, --resource-group    Resource group name (default: $RESOURCE_GROUP)
  -l, --location          Azure location (default: $LOCATION)
  -n, --base-name         Base name for resources (default: $BASE_NAME)
  -h, --help              Show this help message

Examples:
  $0 deploy
  $0 deploy -g my-rg -l westus2
  $0 cleanup
  $0 test

EOF
    exit 1
}

# Parse arguments
COMMAND=""

while [[ $# -gt 0 ]]; do
    case $1 in
        deploy|cleanup|status|test)
            COMMAND="$1"
            shift
            ;;
        -g|--resource-group)
            RESOURCE_GROUP="$2"
            shift 2
            ;;
        -l|--location)
            LOCATION="$2"
            shift 2
            ;;
        -n|--base-name)
            BASE_NAME="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            print_error "Unknown option: $1"
            usage
            ;;
    esac
done

# Main execution
case "$COMMAND" in
    deploy)
        check_prerequisites
        generate_tls_certificate
        deploy_infrastructure
        assign_cluster_roles
        get_cluster_credentials
        install_alb_controller
        deploy_nginx_cluster
        deploy_agc_cluster
        print_summary
        ;;
    cleanup)
        cleanup
        ;;
    status)
        if [[ -f "${ROOT_DIR}/.endpoints.json" ]]; then
            cat "${ROOT_DIR}/.endpoints.json" | jq .
        else
            print_error "No deployment info found. Run 'deploy' first."
        fi
        ;;
    test)
        if [[ -f "${ROOT_DIR}/.endpoints.json" ]]; then
            AGC_ENDPOINT=$(jq -r '.agc.endpoint' "${ROOT_DIR}/.endpoints.json")
            NGINX_ENDPOINT=$(jq -r '.nginx.endpoint' "${ROOT_DIR}/.endpoints.json")
            "${SCRIPT_DIR}/test-performance.sh" -a "$AGC_ENDPOINT" -n "$NGINX_ENDPOINT"
        else
            print_error "No deployment info found. Run 'deploy' first."
        fi
        ;;
    *)
        usage
        ;;
esac
