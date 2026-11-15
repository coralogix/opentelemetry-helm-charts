#!/usr/bin/env bash
# databaseMonitoring preset tests (DBM EC-09), run by `make validate-examples` after validate-configs.sh:
#   1. helm-unittest suite tests/database_monitoring_test.yaml (pinned helm-unittest v1.2.1);
#   2. strict otelcol-contrib validation of the database-monitoring golden render
#      (only the DBM components otelcol-contrib does not ship are removed; no error is ignored).
set -euo pipefail

CHART_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELM_UNITTEST_VERSION="v1.2.1"

if ! helm plugin list 2>/dev/null | awk '{print $1}' | grep -qx unittest; then
    helm plugin install https://github.com/helm-unittest/helm-unittest.git --version "${HELM_UNITTEST_VERSION}"
fi
echo "== helm-unittest: tests/database_monitoring_test.yaml"
helm unittest --file 'tests/database_monitoring_test.yaml' "${CHART_DIR}"

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
