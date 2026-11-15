#!/usr/bin/env bash
# databaseMonitoring preset tests (DBM EC-09), run by `make validate-examples` after validate-configs.sh:
#   1. helm-unittest suite tests/database_monitoring_test.yaml (pinned helm-unittest 1.2.1 binary);
#   2. strict otelcol-contrib validation of the database-monitoring golden render
#      (only the DBM components otelcol-contrib does not ship are removed; no error is ignored).
set -euo pipefail

CHART_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELM_UNITTEST_VERSION="1.2.1"
# The plugin.yaml of helm-unittest 1.x is not loadable by the Helm 3.12 used in CI, so the pinned
# release binary (untt) runs standalone, verified against the release checksums.
declare -A HELM_UNITTEST_SHA256=(
    [linux-amd64]=48e86ecc1467b009630e5954375e5d8494139f73b466df5fe8c04fa45b634939
    [linux-arm64]=c66062713cd3cbb1a80d7098bd1d4a48db8438f56b43fb6377df65447f93f8de
)
UNTT="${UNTT:-}"
workdir="$(mktemp -d)"
trap 'rm -rf "${workdir:?}"' EXIT
if [[ -z "${UNTT}" ]]; then
    os="$(uname -s | tr '[:upper:]' '[:lower:]')"
    case "$(uname -m)" in x86_64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; *) echo "unsupported arch"; exit 1 ;; esac
    platform="${os}-${arch}"
    sha="${HELM_UNITTEST_SHA256[${platform}]:-}"
    if [[ -z "${sha}" ]]; then
        echo "no pinned helm-unittest checksum for ${platform}; set UNTT to a helm-unittest ${HELM_UNITTEST_VERSION} binary"
        exit 1
    fi
    tgz="helm-unittest-${platform}-${HELM_UNITTEST_VERSION}.tgz"
    curl -fsSL -o "${workdir}/${tgz}" "https://github.com/helm-unittest/helm-unittest/releases/download/v${HELM_UNITTEST_VERSION}/${tgz}"
    echo "${sha}  ${workdir}/${tgz}" | sha256sum -c -
    tar -xzf "${workdir}/${tgz}" -C "${workdir}"
    UNTT="${workdir}/untt-${platform}"
fi
echo "== helm-unittest ${HELM_UNITTEST_VERSION}: tests/database_monitoring_test.yaml"
status=0
"${UNTT}" --file 'tests/database_monitoring_test.yaml' --output-type JUnit --output-file "${workdir}/junit.xml" "${CHART_DIR}" || status=$?
# Per-test results for review (JUnit), printed between markers.
echo "----- BEGIN helm-unittest JUnit -----"
cat "${workdir}/junit.xml" 2>/dev/null || true
echo
echo "----- END helm-unittest JUnit -----"
if [[ "${status}" -ne 0 ]]; then
    exit "${status}"
fi

echo "== strict validation: examples/database-monitoring"
if ! python3 -c 'import yaml' 2>/dev/null; then
    python3 -m pip install --quiet 'PyYAML==6.0.3'
fi
COLLECTOR_BINARY="${COLLECTOR_BINARY:-${CHART_DIR}/otelcol-contrib}"
if [[ ! -x "${COLLECTOR_BINARY}" ]]; then
    echo "otelcol-contrib not found at ${COLLECTOR_BINARY} (validate-configs.sh downloads it)"
    exit 1
fi
python3 "${CHART_DIR}/tests/validate_database_monitoring.py" \
    "${CHART_DIR}/examples/database-monitoring/rendered/configmap-statefulset.yaml" \
    "${COLLECTOR_BINARY}"
echo "== databaseMonitoring tests: OVERALL PASS"
