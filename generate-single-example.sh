#!/bin/bash

# Script to manually generate a single example for opentelemetry-collector chart
# Usage: ./generate-single-example.sh <example-name>
# Example: ./generate-single-example.sh daemonset-only

set -e

# Check if example name is provided
if [ -z "$1" ]; then
  echo "Error: Example name is required"
  echo "Usage: $0 <example-name>"
  echo ""
  echo "Available examples:"
  find charts/opentelemetry-collector/examples -type d -maxdepth 1 -mindepth 1 -exec basename {} \; | sort
  exit 1
fi

# Set variables
CHART_NAME="opentelemetry-collector"
EXAMPLE_NAME="$1"
EXAMPLES_DIR="charts/${CHART_NAME}/examples"

# Check if example exists
if [ ! -d "${EXAMPLES_DIR}/${EXAMPLE_NAME}" ]; then
  echo "Error: Example '${EXAMPLE_NAME}' does not exist"
  echo ""
  echo "Available examples:"
  find ${EXAMPLES_DIR} -type d -maxdepth 1 -mindepth 1 -exec basename {} \; | sort
  exit 1
fi

# Check if values.yaml exists
if [ ! -f "${EXAMPLES_DIR}/${EXAMPLE_NAME}/values.yaml" ]; then
  echo "Error: values.yaml not found for example '${EXAMPLE_NAME}'"
  exit 1
fi

echo "Generating example: ${EXAMPLE_NAME}"

# Remove old rendered files
rm -rf "${EXAMPLES_DIR}/${EXAMPLE_NAME}/rendered"

# Generate the templates
helm template example charts/${CHART_NAME} \
  --namespace default \
  --values ${EXAMPLES_DIR}/${EXAMPLE_NAME}/values.yaml \
  --output-dir "${EXAMPLES_DIR}/${EXAMPLE_NAME}/rendered"

# Move files from nested structure to rendered directory
mv ${EXAMPLES_DIR}/${EXAMPLE_NAME}/rendered/${CHART_NAME}/templates/* \
   "${EXAMPLES_DIR}/${EXAMPLE_NAME}/rendered/"

# Handle subcharts if they exist
SUBCHARTS_DIR="${EXAMPLES_DIR}/${EXAMPLE_NAME}/rendered/${CHART_NAME}/charts"
if [ -d "${SUBCHARTS_DIR}" ]; then
  SUBCHARTS=$(find ${SUBCHARTS_DIR} -type d -maxdepth 1 -mindepth 1 -exec basename {} \; 2>/dev/null || true)
  for subchart in ${SUBCHARTS}; do
    mkdir -p "${EXAMPLES_DIR}/${EXAMPLE_NAME}/rendered/${subchart}"
    mv ${SUBCHARTS_DIR}/${subchart}/templates/* "${EXAMPLES_DIR}/${EXAMPLE_NAME}/rendered/${subchart}" 2>/dev/null || true
  done
fi

# Clean up nested directory structure
rm -rf ${EXAMPLES_DIR}/${EXAMPLE_NAME}/rendered/${CHART_NAME}

echo "Completed example: ${EXAMPLE_NAME}"
echo ""
echo "Generated files:"
ls -la "${EXAMPLES_DIR}/${EXAMPLE_NAME}/rendered/"
