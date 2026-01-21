#!/bin/bash
# ============================================================================
# Performance Test Client for AKS Ingress Comparison
# ============================================================================
# This script sends HTTP requests to both ingress endpoints and measures
# response times to compare performance between AGC and NGINX ingress.
# ============================================================================

set -euo pipefail

# Default configuration
TEST_DURATION="${TEST_DURATION:-120s}"
CONCURRENCY="${CONCURRENCY:-10}"
ENDPOINT_PATH="${ENDPOINT_PATH:-/test}"
OUTPUT_DIR="${OUTPUT_DIR:-./results}"
WARMUP_REQUESTS="${WARMUP_REQUESTS:-50}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

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

# Check for required tools
check_prerequisites() {
    print_header "Checking Prerequisites"
    
    local missing_tools=()
    
    for tool in curl jq bc hey; do
        if ! command -v "$tool" &> /dev/null; then
            missing_tools+=("$tool")
        else
            print_info "$tool is installed"
        fi
    done
    
    if [ ${#missing_tools[@]} -ne 0 ]; then
        print_error "Missing required tools: ${missing_tools[*]}"
        echo "Please install them using:"
        echo "  hey: go install github.com/rakyll/hey@latest"
        echo "       or download from https://github.com/rakyll/hey/releases"
        echo "  Ubuntu/Debian: sudo apt-get install curl jq bc"
        echo "  RHEL/CentOS: sudo yum install curl jq bc"
        echo "  macOS: brew install curl jq bc hey"
        exit 1
    fi
}

# Usage information
usage() {
    cat << EOF
Usage: $0 -a <agc-url> -n <nginx-url> [options]

Required arguments:
  -a, --agc-url       URL for AGC ingress endpoint
  -n, --nginx-url     URL for NGINX ingress endpoint

Optional arguments:
  -d, --duration      Test duration (default: $TEST_DURATION)
  -c, --concurrency   Number of concurrent requests (default: $CONCURRENCY)
  -p, --path          Endpoint path to test (default: $ENDPOINT_PATH)
  -o, --output        Output directory for results (default: $OUTPUT_DIR)
  -w, --warmup        Number of warmup requests (default: $WARMUP_REQUESTS)
  -h, --help          Show this help message

Example:
  $0 -a http://agc.example.com -n http://nginx.example.com -d 120s -c 20

EOF
    exit 1
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -a|--agc-url)
                AGC_URL="$2"
                shift 2
                ;;
            -n|--nginx-url)
                NGINX_URL="$2"
                shift 2
                ;;
            -d|--duration)
                TEST_DURATION="$2"
                shift 2
                ;;
            -c|--concurrency)
                CONCURRENCY="$2"
                shift 2
                ;;
            -p|--path)
                ENDPOINT_PATH="$2"
                shift 2
                ;;
            -o|--output)
                OUTPUT_DIR="$2"
                shift 2
                ;;
            -w|--warmup)
                WARMUP_REQUESTS="$2"
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

    # Validate required arguments
    if [[ -z "${AGC_URL:-}" ]] || [[ -z "${NGINX_URL:-}" ]]; then
        print_error "Both AGC and NGINX URLs are required"
        usage
    fi
}

# Create output directory and initialize files
setup_output() {
    print_header "Setting Up Output Directory"
    
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    RESULT_DIR="${OUTPUT_DIR}/${TIMESTAMP}"
    mkdir -p "$RESULT_DIR"
    
    print_info "Results will be saved to: $RESULT_DIR"
    
    # Create summary file
    cat > "${RESULT_DIR}/test_config.json" << EOF
{
    "timestamp": "$(date -Iseconds)",
    "agc_url": "${AGC_URL}${ENDPOINT_PATH}",
    "nginx_url": "${NGINX_URL}${ENDPOINT_PATH}",
    "test_duration": "$TEST_DURATION",
    "concurrency": $CONCURRENCY,
    "warmup_requests": $WARMUP_REQUESTS,
    "endpoint_path": "$ENDPOINT_PATH"
}
EOF
}

# Run warmup requests
run_warmup() {
    local url=$1
    local name=$2
    
    print_info "Running $WARMUP_REQUESTS warmup requests for $name..."
    
    for i in $(seq 1 "$WARMUP_REQUESTS"); do
        curl -s -o /dev/null -w "" "$url" || true
    done
    
    print_info "Warmup complete for $name"
}

# Run hey benchmark test and parse results
run_hey_test() {
    local url=$1
    local name=$2
    local output_file="${RESULT_DIR}/${name}_hey.txt"
    
    print_info "Running hey benchmark test for $name..."
    print_info "URL: $url"
    print_info "Duration: $TEST_DURATION, Concurrency: $CONCURRENCY"
    
    # Run hey and capture output (duration-based test)
    hey -z "$TEST_DURATION" -c "$CONCURRENCY" "$url" > "$output_file" 2>&1
    
    # Parse results from hey output
    local requests_per_sec=$(grep "Requests/sec:" "$output_file" | awk '{print $2}')
    local total_time=$(grep "Total:" "$output_file" | head -1 | awk '{print $2}')
    local avg_latency=$(grep "Average:" "$output_file" | head -1 | awk '{print $2}')
    
    # Get status code distribution - this gives us total successful requests
    local status_200=$(grep "\[200\]" "$output_file" | awk '{print $2}' || echo "0")
    
    # Get total requests from the summary line (e.g., "37311 requests in 120.03s")
    local total_requests=$(grep "requests in" "$output_file" | awk '{print $1}')
    
    # Calculate failed requests using bc for floating point safety
    local failed_requests=$(echo "${total_requests:-0} - ${status_200:-0}" | bc 2>/dev/null || echo "0")
    
    # Parse latency distribution (hey outputs in seconds, convert to ms)
    local p50=$(grep "50% in" "$output_file" | awk '{print $3}' | sed 's/secs//')
    local p75=$(grep "75% in" "$output_file" | awk '{print $3}' | sed 's/secs//')
    local p90=$(grep "90% in" "$output_file" | awk '{print $3}' | sed 's/secs//')
    local p95=$(grep "95% in" "$output_file" | awk '{print $3}' | sed 's/secs//')
    local p99=$(grep "99% in" "$output_file" | awk '{print $3}' | sed 's/secs//')
    
    # Convert seconds to milliseconds
    p50_ms=$(echo "scale=2; ${p50:-0} * 1000" | bc 2>/dev/null || echo "0")
    p75_ms=$(echo "scale=2; ${p75:-0} * 1000" | bc 2>/dev/null || echo "0")
    p90_ms=$(echo "scale=2; ${p90:-0} * 1000" | bc 2>/dev/null || echo "0")
    p95_ms=$(echo "scale=2; ${p95:-0} * 1000" | bc 2>/dev/null || echo "0")
    p99_ms=$(echo "scale=2; ${p99:-0} * 1000" | bc 2>/dev/null || echo "0")
    avg_ms=$(echo "scale=2; ${avg_latency:-0} * 1000" | bc 2>/dev/null || echo "0")
    
    # Save parsed results as JSON
    cat > "${RESULT_DIR}/${name}_results.json" << EOF
{
    "endpoint": "$name",
    "url": "$url",
    "test_duration": "$TEST_DURATION",
    "requests_per_second": ${requests_per_sec:-0},
    "avg_latency_ms": ${avg_ms},
    "total_time_seconds": ${total_time:-0},
    "total_requests": ${total_requests:-0},
    "successful_requests": ${status_200:-0},
    "failed_requests": ${failed_requests:-0},
    "percentiles": {
        "p50_ms": ${p50_ms},
        "p75_ms": ${p75_ms},
        "p90_ms": ${p90_ms},
        "p95_ms": ${p95_ms},
        "p99_ms": ${p99_ms}
    }
}
EOF

    print_info "Results saved to ${RESULT_DIR}/${name}_results.json"
    print_info "  Requests/sec: ${requests_per_sec:-0}"
    print_info "  Avg latency: ${avg_ms}ms"
    print_info "  P99 latency: ${p99_ms}ms"
}

# Run custom curl-based latency test with detailed timing
run_curl_test() {
    local url=$1
    local name=$2
    local output_file="${RESULT_DIR}/${name}_curl_latencies.csv"
    
    print_info "Running detailed latency test for $name..."
    
    # CSV header
    echo "request_num,dns_lookup_ms,tcp_connect_ms,tls_handshake_ms,ttfb_ms,total_time_ms,http_code" > "$output_file"
    
    local success_count=0
    local fail_count=0
    
    for i in $(seq 1 100); do
        result=$(curl -s -o /dev/null -w "%{time_namelookup},%{time_connect},%{time_appconnect},%{time_starttransfer},%{time_total},%{http_code}" "$url" 2>/dev/null || echo "0,0,0,0,0,0")
        
        # Convert to milliseconds
        IFS=',' read -r dns tcp tls ttfb total code <<< "$result"
        dns_ms=$(echo "$dns * 1000" | bc 2>/dev/null || echo "0")
        tcp_ms=$(echo "$tcp * 1000" | bc 2>/dev/null || echo "0")
        tls_ms=$(echo "$tls * 1000" | bc 2>/dev/null || echo "0")
        ttfb_ms=$(echo "$ttfb * 1000" | bc 2>/dev/null || echo "0")
        total_ms=$(echo "$total * 1000" | bc 2>/dev/null || echo "0")
        
        echo "$i,$dns_ms,$tcp_ms,$tls_ms,$ttfb_ms,$total_ms,$code" >> "$output_file"
        
        if [[ "$code" == "200" ]]; then
            success_count=$((success_count + 1))
        else
            fail_count=$((fail_count + 1))
        fi
        
        # Progress indicator
        if [[ $((i % 10)) -eq 0 ]]; then
            printf "."
        fi
    done
    echo ""
    
    print_info "Detailed latency test complete: $success_count successful, $fail_count failed"
}

# Generate comparison summary
generate_summary() {
    print_header "Generating Comparison Summary"
    
    local agc_results="${RESULT_DIR}/agc_results.json"
    local nginx_results="${RESULT_DIR}/nginx_results.json"
    
    if [[ ! -f "$agc_results" ]] || [[ ! -f "$nginx_results" ]]; then
        print_error "Results files not found"
        return 1
    fi
    
    # Extract values
    local agc_rps=$(jq '.requests_per_second' "$agc_results")
    local nginx_rps=$(jq '.requests_per_second' "$nginx_results")
    local agc_avg=$(jq '.avg_latency_ms' "$agc_results")
    local nginx_avg=$(jq '.avg_latency_ms' "$nginx_results")
    local agc_p50=$(jq '.percentiles.p50_ms' "$agc_results")
    local nginx_p50=$(jq '.percentiles.p50_ms' "$nginx_results")
    local agc_p95=$(jq '.percentiles.p95_ms' "$agc_results")
    local nginx_p95=$(jq '.percentiles.p95_ms' "$nginx_results")
    local agc_p99=$(jq '.percentiles.p99_ms' "$agc_results")
    local nginx_p99=$(jq '.percentiles.p99_ms' "$nginx_results")
    local agc_failed=$(jq '.failed_requests' "$agc_results")
    local nginx_failed=$(jq '.failed_requests' "$nginx_results")
    
    # Calculate percentage differences
    local rps_diff=$(echo "scale=2; (($nginx_rps - $agc_rps) / $agc_rps) * 100" | bc 2>/dev/null || echo "N/A")
    local p50_diff=$(echo "scale=2; (($nginx_p50 - $agc_p50) / $agc_p50) * 100" | bc 2>/dev/null || echo "N/A")
    local p95_diff=$(echo "scale=2; (($nginx_p95 - $agc_p95) / $agc_p95) * 100" | bc 2>/dev/null || echo "N/A")
    local p99_diff=$(echo "scale=2; (($nginx_p99 - $agc_p99) / $agc_p99) * 100" | bc 2>/dev/null || echo "N/A")
    
    # Create summary
    cat > "${RESULT_DIR}/summary.json" << EOF
{
    "timestamp": "$(date -Iseconds)",
    "test_config": {
        "duration": "$TEST_DURATION",
        "concurrency": $CONCURRENCY
    },
    "results": {
        "agc": {
            "requests_per_second": $agc_rps,
            "avg_latency_ms": $agc_avg,
            "p50_ms": $agc_p50,
            "p95_ms": $agc_p95,
            "p99_ms": $agc_p99,
            "failed_requests": $agc_failed
        },
        "nginx": {
            "requests_per_second": $nginx_rps,
            "avg_latency_ms": $nginx_avg,
            "p50_ms": $nginx_p50,
            "p95_ms": $nginx_p95,
            "p99_ms": $nginx_p99,
            "failed_requests": $nginx_failed
        }
    },
    "comparison": {
        "rps_difference_percent": "$rps_diff",
        "p50_difference_percent": "$p50_diff",
        "p95_difference_percent": "$p95_diff",
        "p99_difference_percent": "$p99_diff",
        "faster_rps": "$(echo "$agc_rps > $nginx_rps" | bc -l | grep -q 1 && echo 'AGC' || echo 'NGINX')",
        "lower_latency_p50": "$(echo "$agc_p50 < $nginx_p50" | bc -l | grep -q 1 && echo 'AGC' || echo 'NGINX')"
    }
}
EOF

    # Print summary to console
    print_header "Performance Comparison Results"
    
    echo -e "${GREEN}=== Throughput (Requests/Second) ===${NC}"
    printf "%-20s %15s\n" "AGC:" "$agc_rps req/s"
    printf "%-20s %15s\n" "NGINX:" "$nginx_rps req/s"
    printf "%-20s %15s%%\n" "Difference:" "$rps_diff"
    echo ""
    
    echo -e "${GREEN}=== Latency Percentiles (ms) ===${NC}"
    printf "%-10s %10s %10s %10s\n" "Ingress" "P50" "P95" "P99"
    printf "%-10s %10s %10s %10s\n" "AGC" "$agc_p50" "$agc_p95" "$agc_p99"
    printf "%-10s %10s %10s %10s\n" "NGINX" "$nginx_p50" "$nginx_p95" "$nginx_p99"
    echo ""
    
    echo -e "${GREEN}=== Winner ===${NC}"
    echo "Higher Throughput: $(echo "$agc_rps > $nginx_rps" | bc -l | grep -q 1 && echo -e "${BLUE}AGC${NC}" || echo -e "${YELLOW}NGINX${NC}")"
    echo "Lower Latency (P50): $(echo "$agc_p50 < $nginx_p50" | bc -l | grep -q 1 && echo -e "${BLUE}AGC${NC}" || echo -e "${YELLOW}NGINX${NC}")"
    
    print_info "Full results saved to: ${RESULT_DIR}/summary.json"
}

# Main execution
main() {
    print_header "AKS Ingress Performance Test"
    
    parse_args "$@"
    check_prerequisites
    setup_output
    
    # Full URLs
    AGC_FULL_URL="${AGC_URL}${ENDPOINT_PATH}"
    NGINX_FULL_URL="${NGINX_URL}${ENDPOINT_PATH}"
    
    # Verify endpoints are reachable
    print_header "Verifying Endpoints"
    
    if curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$AGC_FULL_URL" | grep -q "200"; then
        print_info "AGC endpoint is reachable"
    else
        print_error "AGC endpoint is not reachable: $AGC_FULL_URL"
        exit 1
    fi
    
    if curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$NGINX_FULL_URL" | grep -q "200"; then
        print_info "NGINX endpoint is reachable"
    else
        print_error "NGINX endpoint is not reachable: $NGINX_FULL_URL"
        exit 1
    fi
    
    # Run hey benchmark tests with warmup before each
    print_header "Load Testing with hey"
    
    print_info "=== Testing AGC ==="
    run_warmup "$AGC_FULL_URL" "AGC"
    run_hey_test "$AGC_FULL_URL" "agc"
    
    print_info "=== Testing NGINX ==="
    run_warmup "$NGINX_FULL_URL" "NGINX"
    run_hey_test "$NGINX_FULL_URL" "nginx"
    
    # Run detailed latency tests
    print_header "Detailed Latency Analysis"
    run_curl_test "$AGC_FULL_URL" "agc"
    run_curl_test "$NGINX_FULL_URL" "nginx"
    
    # Generate summary
    generate_summary
    
    print_header "Test Complete"
    print_info "All results saved to: $RESULT_DIR"
}

# Run main function with all arguments
main "$@"
