# AKS Ingress Performance Comparison

This project deploys infrastructure for comparing two different ingress solutions on Azure Kubernetes Service (AKS):

1. **Application Gateway for Containers (AGC)** - Azure's next-generation Layer 7 load balancer
2. **Managed NGINX Ingress** - Web Application Routing add-on for AKS

Both clusters use **Azure CNI Powered by Cilium** for consistent networking performance.

## Prerequisites

- Azure CLI (`az`) installed and authenticated
- `kubectl` installed
- `helm` installed
- `jq` installed
- `bc` installed (for performance tests)
- `hey` installed (for performance tests) - [github.com/rakyll/hey](https://github.com/rakyll/hey)

## Quick Start

### 1. Clone the Repository

```bash
git clone git@github.com:pelithne/aks-ingress-comparison.git
cd aks-ingress-comparison
```

### 2. Deploy Infrastructure and k8s Workloads

```bash
# Deploy with defaults
./scripts/deploy.sh deploy

# Or with custom options
./scripts/deploy.sh deploy -g my-rg -l northeurope -n mytest
```

### 2. Run Performance Tests

```bash
# Use endpoints from the "Deployment Summary"
./scripts/test-performance.sh -a http://agc-endpoint -n http://nginx-endpoint
```

### 3. Cleanup

```bash
./scripts/deploy.sh cleanup
```

## Test Endpoints

The demo application exposes:

| Endpoint | Description |
|----------|-------------|
| `/` | HTML page with application info |
| `/api/time` | JSON response with timestamp (ideal for latency testing) |
| `/health` | Health check endpoint |

## Performance Test Output

The test script generates:

- `summary.json` - Comparison summary with winner determination

Example output:

```
=== Throughput (Requests/Second) ===
AGC:                 1234.56 req/s
NGINX:               1189.23 req/s
Difference:          -3.67%

=== Latency Percentiles (ms) ===
Ingress         P50        P95        P99
AGC              12         45         89
NGINX            14         52         95

=== Winner ===
Higher Throughput: AGC
Lower Latency (P50): AGC
```

## Configuration

### Bicep Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `location` | Resource group location | Azure region |
| `baseName` | `akstest` | Base name for resources |
| `kubernetesVersion` | `1.32` | Kubernetes version |
| `nodeVmSize` | `Standard_DS4_v6` | VM size for nodes |
| `nodeCount` | `1` | Initial node count |

## Ingress Comparison

| Feature | AGC | Managed NGINX |
|---------|-----|---------------|
| **Type** | Layer 7 Load Balancer | Ingress Controller |
| **API** | Gateway API | Kubernetes Ingress |
| **Managed By** | Azure | AKS Add-on |
| **TLS Termination** | Yes | Yes |
| **Path-based Routing** | Yes | Yes |
| **Backend Health** | Yes | Yes |
| **Autoscaling** | Yes (Azure managed) | HPA |
| **Zone Redundancy** | Built-in | Via node placement |


## License

MIT
