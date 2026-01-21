# AKS Ingress Performance Comparison

This project deploys infrastructure for comparing two different ingress solutions on Azure Kubernetes Service (AKS):

1. **Application Gateway for Containers (AGC)** - Azure's next-generation Layer 7 load balancer with native Gateway API support
2. **Managed NGINX Ingress** - Web Application Routing add-on fronted by Azure Application Gateway v2

Both clusters use **Azure CNI Powered by Cilium**.

## Features

- **HTTPS with TLS termination** on both ingress solutions
- **Web Application Firewall (WAF)** enabled on both gateways
  - AGC: Uses SecurityPolicy CRD with Microsoft_DefaultRuleSet 2.1
  - NGINX: Uses Application Gateway WAF v2 with OWASP 3.2 ruleset
- **Self-signed certificates** for testing (automatically generated)
- **Fair comparison** with WAF in Detection mode to avoid blocking test traffic

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                         AGC Cluster                                 │
│  Client → AGC (HTTPS + WAF) → Gateway API → NGINX Pod               │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│                        NGINX Cluster                                │
│  Client → App Gateway v2 (HTTPS + WAF) → NGINX Ingress → NGINX Pod  │
└─────────────────────────────────────────────────────────────────────┘
```

## Prerequisites

- Azure CLI (`az`) installed and authenticated
- `kubectl` installed
- `helm` installed
- `jq` installed
- `openssl` installed (for certificate generation)
- `bc` installed (for performance tests)
- `hey` installed (for performance tests) - [github.com/rakyll/hey](https://github.com/rakyll/hey)

## Quick Start

### 1. Clone the Repository

```bash
git clone git@github.com:pelithne/aks-ingress-comparison.git
cd aks-ingress-comparison
```

### 2. Deploy Infrastructure and Workloads

```bash
# Deploy with defaults
./scripts/deploy.sh deploy

# Or with custom options
./scripts/deploy.sh deploy -g my-rg -l northeurope -n mytest
```

The deployment creates:
- Two AKS clusters (one for AGC, one for NGINX)
- Virtual network with subnets for each cluster and AGC
- Application Gateway v2 with WAF for NGINX cluster
- ALB Controller for AGC cluster
- Self-signed TLS certificates
- Demo application on both clusters

### 3. Run Performance Tests

```bash
# Use endpoints from the "Deployment Summary"
# The -k flag is required for self-signed certificates
./scripts/test-performance.sh \
  -a https://agc-endpoint.alb.azure.com \
  -n https://nginx-endpoint.northeurope.cloudapp.azure.com \
  -k
```

**Note:** The `-k` flag allows the test to accept self-signed certificates.

### 4. Cleanup

```bash
./scripts/deploy.sh cleanup
```

## Test Endpoints

The demo application exposes:

| Endpoint | Description |
|----------|-------------|
| `/` | HTML page with application info |
| `/test` | Static JSON response (used for performance testing) |
| `/health` | Health check endpoint |

## Testing with curl

When testing HTTPS endpoints with self-signed certificates:

```bash
# Test AGC endpoint
curl -ks https://your-agc-endpoint.alb.azure.com/test

# Test NGINX endpoint (via Application Gateway)
curl -ks https://your-nginx-endpoint.northeurope.cloudapp.azure.com/test

# Verify WAF is logging (Detection mode - returns 200, logged in WAF logs)
curl -ks "https://your-endpoint/test?id=1'%20OR%20'1'='1"
```

## Performance Test Output

The test script generates results in `./results/<timestamp>/`:

- `summary.json` - Comparison summary with throughput and latency metrics
- `agc_results.json` - Detailed AGC test results
- `nginx_results.json` - Detailed NGINX test results
- `*_hey.txt` - Raw output from hey benchmark tool
- `*_curl_latencies.csv` - Detailed latency breakdown per request

## Configuration

### Bicep Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `location` | Resource group location | Azure region |
| `baseName` | `akstest` | Base name for resources |
| `kubernetesVersion` | `1.32` | Kubernetes version |
| `nodeVmSize` | `Standard_DS4_v6` | VM size for nodes |
| `nodeCount` | `1` | Initial node count |

### Performance Test Options

| Option | Default | Description |
|--------|---------|-------------|
| `-d, --duration` | `120s` | Test duration |
| `-c, --concurrency` | `10` | Concurrent connections |
| `-p, --path` | `/test` | Endpoint path to test |
| `-k, --insecure` | `false` | Accept self-signed certificates |
| `-w, --warmup` | `50` | Warmup requests before test |

## WAF Configuration

Both WAF policies are configured in **Detection mode** for fair performance comparison:

- **AGC WAF**: Microsoft_DefaultRuleSet version 2.1
- **Application Gateway WAF**: OWASP Core Rule Set version 3.2

To switch to Prevention mode (blocking), update the Bicep templates:
- `infra/main.bicep` - AGC WAF policy
- `infra/modules/appgw.bicep` - Application Gateway WAF policy

## License

MIT
