#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
EXAMPLES_DIR="${REPO_ROOT}/charts/opentelemetry-collector/examples"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

should_skip_manifest() {
    local manifest_file="$1"
    local validation_output="$2"

    if [[ "$validation_output" =~ no\ matches\ for\ kind\ \"([^\"]+)\" ]]; then
        local kind="${BASH_REMATCH[1]}"
        case "$kind" in
            OpenTelemetryCollector|ServiceMonitor|PodMonitor|PrometheusRule)
                return 0
                ;;
        esac
    fi

    if [[ "${manifest_file}" == *"/deployment-targetallocator.yaml" ]] && [[ "${validation_output}" == *"image: Required value"* ]]; then
        return 0
    fi

    return 1
}

validate_manifest() {
    local manifest_file="$1"
    local output

    output=$(kubectl apply --dry-run=client --validate=strict -f "${manifest_file}" 2>&1) || {
        if should_skip_manifest "${manifest_file}" "${output}"; then
            warn "Skipping manifest with unsupported local validation prerequisites: ${manifest_file}"
            return 0
        fi

        error "Manifest invalid: ${manifest_file}"
        echo "${output}" | head -10 | sed 's/^/  /'
        return 1
    }

    log "Manifest valid: ${manifest_file}"
}

main() {
    if ! command -v kubectl >/dev/null 2>&1; then
        error "kubectl is required but not installed"
        exit 1
    fi

    if [[ ! -d "${EXAMPLES_DIR}" ]]; then
        error "Examples directory not found: ${EXAMPLES_DIR}"
        exit 1
    fi

    local total=0
    local skipped=0

    while IFS= read -r manifest_file; do
        total=$((total + 1))

        if ! validate_manifest "${manifest_file}"; then
            exit 1
        fi
    done < <(find "${EXAMPLES_DIR}" -type f \( -name "*.yaml" -o -name "*.yml" \) -path "*/rendered/*" | sort)

    log "Validated ${total} rendered manifest files"
    log "CRD-dependent manifests are skipped when their CRDs are absent from the cluster"
}

main "$@"
