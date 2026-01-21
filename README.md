# AKS Ingress Performance Comparison

This project deploys infrastructure for comparing two different ingress solutions on Azure Kubernetes Service (AKS):

1. **Application Gateway for Containers (AGC)** - Azure's next-generation Layer 7 load balancer
2. **Managed NGINX Ingress** - Web Application Routing add-on for AKS

Both clusters use **Azure CNI Powered by Cilium** for consistent networking performance.

## Architecture

```
                    ┌───────────────────────────────────────────┐
                    │              Azure Resource Group         │
                    │                                           │
   ┌────────────────┼───────────────────────────────────────────┼──────────────────────┐
   │                │                                           │                      │
   │    ┌───────────┴─────────────┐          ┌──────────────────┴──────────────────┐   │
   │    │  AGC Traffic Controller │          │          Virtual Network            │   │
   │    │  (snet-agc: 10.3.0.0/24)│          │          (10.0.0.0/8)               │   │
   │    └───────────┬─────────────┘          └──────────────────┬──────────────────┘   │
   │                │                                           │                      │
   │    ┌───────────┴───────────┐            ┌──────────────────┴──────────────────┐   │
   │    │   AKS Cluster (AGC)   │            │        AKS Cluster (NGINX)          │   │
   │    │   snet-aks-agc        │            │        snet-aks-nginx               │   │
   │    │   (10.1.0.0/16)       │            │        (10.2.0.0/16)                │   │
   │    │                       │            │                                     │   │
   │    │  ┌─────────────────┐  │            │       ┌─────────────────┐           │   │
   │    │  │  Demo App       │  │            │       │  Demo App       │           │   │
   │    │  │  (3 replicas)   │  │            │       │  (3 replicas)   │           │   │
   │    │  └────────┬────────┘  │            │       └────────┬────────┘           │   │
   │    │           │           │            │                │                    │   │
   │    │  ┌────────┴────────┐  │            │       ┌────────┴────────┐           │   │
   │    │  │  Gateway API    │  │            │       │  NGINX Ingress  │           │   │
   │    │  │  (HTTPRoute)    │  │            │       │  (WAR Add-on)   │           │   │
   │    │  └─────────────────┘  │            │       └─────────────────┘           │   │
   │    └───────────────────────┘            └─────────────────────────────────────┘   │
   │                                                                                   │
   └───────────────────────────────────────────────────────────────────────────────────┘
```

## Features

- **Azure CNI Powered by Cilium** - eBPF-based networking for high-performance
- **Azure RBAC for Kubernetes** - Integrated access management


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

### 2. Deploy Infrastructure

```bash
# Deploy with defaults
./scripts/deploy.sh deploy

# Or with custom options
./scripts/deploy.sh deploy -g my-rg -l westus2 -n mytest
```

### 2. Run Performance Tests

```bash
# Using saved endpoints
./scripts/deploy.sh test

# Or manually specify endpoints
./scripts/test-performance.sh -a http://agc-endpoint -n http://nginx-endpoint
```

### 3. Cleanup

```bash
./scripts/deploy.sh cleanup
```

## Project Structure

```
.
├── infra/
│   ├── main.bicep                  # Main orchestration template
│   └── modules/
│       ├── network.bicep           # VNet and subnets
│       ├── aks-agc.bicep           # AKS cluster for AGC
│       ├── aks-nginx.bicep         # AKS cluster with managed NGINX
│       └── agc.bicep               # Application Gateway for Containers
├── k8s/
│   ├── common/
│   │   └── demo-app.yaml           # Sample web application
│   ├── agc-cluster/
│   │   ├── alb-controller-config.yaml  # ALB Controller configuration
│   │   └── gateway.yaml            # Gateway API resources
│   └── nginx-cluster/
│       └── ingress.yaml            # NGINX Ingress configuration
├── scripts/
│   ├── deploy.sh                   # Deployment orchestration script
│   └── test-performance.sh         # Performance testing script
└── README.md                       # This file
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
- `agc_results.json` / `nginx_results.json` - Detailed Apache Bench results
- `agc_curl_latencies.csv` / `nginx_curl_latencies.csv` - Detailed timing data
- `agc_gnuplot.tsv` / `nginx_gnuplot.tsv` - Data for visualization

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

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `RESOURCE_GROUP` | `rg-aks-ingress-test` | Azure resource group name |
| `LOCATION` | `eastus2` | Azure region |
| `BASE_NAME` | `akstest` | Base name for resources |
| `NUM_REQUESTS` | `1000` | Number of test requests |
| `CONCURRENCY` | `10` | Concurrent connections |

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

## Troubleshooting

### Check cluster status
```bash
kubectl config use-context agc-cluster
kubectl get pods -n demo-app
kubectl get gateway -n demo-app

kubectl config use-context nginx-cluster  
kubectl get pods -n demo-app
kubectl get ingress -n demo-app
```

### View logs
```bash
# AGC cluster
kubectl logs -l app=demo-app -n demo-app --context agc-cluster

# NGINX cluster
kubectl logs -l app=demo-app -n demo-app --context nginx-cluster
```

### Check ALB Controller
```bash
kubectl get pods -n azure-alb-system --context agc-cluster
kubectl logs -l app=alb-controller -n azure-alb-system --context agc-cluster
```

## License

MIT
