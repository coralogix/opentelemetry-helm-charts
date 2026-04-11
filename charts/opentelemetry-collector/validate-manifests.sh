#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXAMPLES_DIR="${SCRIPT_DIR}/examples"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

usage() {
    cat <<EOF
Usage: $(basename "$0")

Validates rendered Kubernetes example manifests with kubectl using:
  kubectl apply --dry-run=server --validate=strict

A reachable Kubernetes API server is required.
EOF
}

validate_args() {
    if [[ $# -eq 0 ]]; then
        return
    fi

    if [[ $# -eq 1 && ( "$1" == "-h" || "$1" == "--help" ) ]]; then
        usage
        exit 0
    fi

    error "Unknown argument(s): $*"
    usage
    exit 1
}

ensure_kubectl_available() {
    if ! command -v kubectl >/dev/null 2>&1; then
        error "kubectl is required but not installed"
        exit 1
    fi
}

ensure_cluster_reachable() {
    if ! kubectl version --request-timeout=5s >/dev/null 2>&1; then
        error "Kubernetes API server is not reachable for kubectl"
        error "Configure your kubeconfig/context and retry"
        exit 1
    fi
}

should_skip_manifest() {
    local validation_output="$1"

    if [[ "$validation_output" =~ no\ matches\ for\ kind\ \"([^\"]+)\" ]]; then
        local kind="${BASH_REMATCH[1]}"
        case "$kind" in
            OpenTelemetryCollector|ServiceMonitor|PodMonitor|PrometheusRule)
                return 0
                ;;
            *)
                return 1
                ;;
        esac
    fi

    return 1
}

validate_manifest() {
    local manifest_file="$1"

    local output
    output=$(kubectl apply --dry-run=server --validate=strict -f "${manifest_file}" 2>&1) || {
        if should_skip_manifest "${output}"; then
            warn "Skipping CRD-dependent manifest: ${manifest_file}"
            return 2
        fi

        error "✗ Manifest invalid: ${manifest_file}"
        echo "Validation errors:"
        echo "${output}" | head -10 | sed 's/^/  /'
        return 1
    }

    log "✓ Manifest valid: ${manifest_file}"
    return 0
}

main() {
    validate_args "$@"
    ensure_kubectl_available
    ensure_cluster_reachable

    if [[ ! -d "${EXAMPLES_DIR}" ]]; then
        error "Examples directory not found: ${EXAMPLES_DIR}"
        exit 1
    fi

    local total=0
    local valid=0
    local invalid=0
    local skipped=0

    log "Starting Kubernetes manifest validation"
    log "Scanning rendered manifests in: ${EXAMPLES_DIR}"
    echo ""

    while IFS= read -r manifest_file; do
        total=$((total + 1))

        if validate_manifest "${manifest_file}"; then
            valid=$((valid + 1))
        else
            exit_code=$?
            if [[ ${exit_code} -eq 2 ]]; then
                skipped=$((skipped + 1))
            else
                invalid=$((invalid + 1))
            fi
        fi
    done < <(find "${EXAMPLES_DIR}" -type f \( -name "*.yaml" -o -name "*.yml" \) -path "*/rendered/*" | sort)

    echo ""
    echo "============================================"
    log "Validation Summary:"
    log "Total manifests processed: ${total}"
    log "Valid manifests: ${valid}"
    log "Invalid manifests: ${invalid}"
    log "Skipped manifests: ${skipped}"
    echo ""

    if [[ ${invalid} -gt 0 ]]; then
        error "Found ${invalid} invalid manifest(s)!"
        exit 1
    fi

    log "All validated manifests are valid! ✓"
}

main "$@"
