TMP_DIRECTORY = ./tmp
CHARTS ?= opentelemetry-collector opentelemetry-operator opentelemetry-demo opentelemetry-ebpf opentelemetry-ebpf-instrumentation
MAX_PARALLEL_EXAMPLES ?= $(shell nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)

# Reusable parallel execution with ordered logging utility
define run_parallel_with_logging
	RUNNING_JOBS=0; \
	RUNNING_PIDS=""; \
	FAILED=0; \
	EXAMPLE_ORDER=""; \
	mkdir -p "$(TMP_DIRECTORY)/logs"; \
	for example in $(1); do \
		EXAMPLE_ORDER="$${EXAMPLE_ORDER} $${example}"; \
		{ \
			LOG_FILE="$(TMP_DIRECTORY)/logs/$(2)-$${example}.log"; \
			{ set -e; $(3); } > "$${LOG_FILE}" 2>&1; \
		} & \
		RUNNING_PIDS="$${RUNNING_PIDS} $$!"; \
		RUNNING_JOBS=$$(($$RUNNING_JOBS + 1)); \
		if [ $$RUNNING_JOBS -ge $(MAX_PARALLEL_EXAMPLES) ]; then \
			for pid in $${RUNNING_PIDS}; do \
				if ! wait "$${pid}"; then \
					FAILED=1; \
				fi; \
			done; \
			RUNNING_PIDS=""; \
			RUNNING_JOBS=0; \
		fi; \
	done; \
	for pid in $${RUNNING_PIDS}; do \
		if ! wait "$${pid}"; then \
			FAILED=1; \
		fi; \
	done; \
	for example in $${EXAMPLE_ORDER}; do \
		LOG_FILE="$(TMP_DIRECTORY)/logs/$(2)-$${example}.log"; \
		if [ -f "$${LOG_FILE}" ]; then \
			cat "$${LOG_FILE}"; \
			echo "--------------------------------"; \
			rm -f "$${LOG_FILE}"; \
		fi; \
	done; \
	rm -rf "$(TMP_DIRECTORY)/logs"; \
	if [ $$FAILED -ne 0 ]; then exit 1; fi
endef

.PHONY: generate-examples
generate-examples:
	for chart_name in $(CHARTS); do \
		echo "Processing chart: $${chart_name} (max $(MAX_PARALLEL_EXAMPLES) parallel examples)"; \
		EXAMPLES_DIR=charts/$${chart_name}/examples; \
		EXAMPLES=$$(find $${EXAMPLES_DIR} -type d -maxdepth 1 -mindepth 1 -exec basename \{\} \;); \
		helm dependency build charts/$${chart_name}; \
		$(call run_parallel_with_logging,$${EXAMPLES},$${chart_name}, \
			echo "Generating example: $${example}"; \
			VALUES=$$(find $${EXAMPLES_DIR}/$${example} -name '*values.yaml'); \
			EXAMPLE_TMP="$(TMP_DIRECTORY)/generate-$${chart_name}-$${example}"; \
			rm -rf "$${EXAMPLE_TMP}"; \
			for value in $${VALUES}; do \
				printf "Using values file: $${value}\n"; \
				helm template example charts/$${chart_name} --namespace default --values $${value} --output-dir "$${EXAMPLE_TMP}"; \
				mv $${EXAMPLE_TMP}/$${chart_name}/templates/* "$${EXAMPLE_TMP}"; \
				SUBCHARTS_DIR=$${EXAMPLE_TMP}/$${chart_name}/charts; \
				if [ -d "$${SUBCHARTS_DIR}" ]; then \
					SUBCHARTS=$$(find $${SUBCHARTS_DIR} -type d -maxdepth 1 -mindepth 1 -exec basename \{\} \; 2>/dev/null || true); \
					for subchart in $${SUBCHARTS}; do \
						mkdir -p "$${EXAMPLE_TMP}/$${subchart}"; \
						mv $${SUBCHARTS_DIR}/$${subchart}/templates/* "$${EXAMPLE_TMP}/$${subchart}" 2>/dev/null || true; \
					done; \
				fi; \
				rm -rf "$${EXAMPLE_TMP}/$${chart_name}"; \
			done; \
			find "$${EXAMPLE_TMP}" -type f \( -name '*.yaml' -o -name '*.yml' \) -exec sed -i.bak -e :a -e '/^[[:space:]]*$$/{$$d;N;ba' -e '}' {} +; \
			find "$${EXAMPLE_TMP}" -type f \( -name '*.yaml.bak' -o -name '*.yml.bak' \) -exec rm -f {} +; \
			rm -rf "$${EXAMPLES_DIR}/$${example}/rendered"; \
			mv "$${EXAMPLE_TMP}" "$${EXAMPLES_DIR}/$${example}/rendered"; \
			printf "Completed example: $${example}\n" \
		); \
		echo "Completed chart: $${chart_name}"; \
	done

.PHONY: check-examples
check-examples:
	for chart_name in $(CHARTS); do \
		echo "Checking chart: $${chart_name} (max $(MAX_PARALLEL_EXAMPLES) parallel examples)"; \
		EXAMPLES_DIR=charts/$${chart_name}/examples; \
		EXAMPLES=$$(find $${EXAMPLES_DIR} -type d -maxdepth 1 -mindepth 1 -exec basename \{\} \;); \
		helm dependency build charts/$${chart_name}; \
		$(call run_parallel_with_logging,$${EXAMPLES},$${chart_name}, \
			echo "Checking example: $${example}"; \
			EXAMPLE_TMP="$(TMP_DIRECTORY)/check-$${chart_name}-$${example}"; \
			rm -rf "$${EXAMPLE_TMP}"; \
			VALUES=$$(find $${EXAMPLES_DIR}/$${example} -name '*values.yaml'); \
			for value in $${VALUES}; do \
				helm template example charts/$${chart_name} --namespace default --values $${value} --output-dir "$${EXAMPLE_TMP}"; \
				SUBCHARTS_DIR=$${EXAMPLE_TMP}/$${chart_name}/charts; \
				if [ -d "$${SUBCHARTS_DIR}" ]; then \
					SUBCHARTS=$$(find $${SUBCHARTS_DIR} -type d -maxdepth 1 -mindepth 1 -exec basename \{\} \; 2>/dev/null || true); \
					for subchart in $${SUBCHARTS}; do \
						mkdir -p "$${EXAMPLE_TMP}/$${chart_name}/templates/$${subchart}"; \
						mv $${SUBCHARTS_DIR}/$${subchart}/templates/* "$${EXAMPLE_TMP}/$${chart_name}/templates/$${subchart}" 2>/dev/null || true; \
					done; \
				fi; \
			done; \
			find "$${EXAMPLE_TMP}/$${chart_name}/templates" -type f \( -name '*.yaml' -o -name '*.yml' \) -exec sed -i.bak -e :a -e '/^[[:space:]]*$$/{$$d;N;ba' -e '}' {} +; \
			find "$${EXAMPLE_TMP}/$${chart_name}/templates" -type f \( -name '*.yaml.bak' -o -name '*.yml.bak' \) -exec rm -f {} +; \
			if diff -r "$${EXAMPLES_DIR}/$${example}/rendered" "$${EXAMPLE_TMP}/$${chart_name}/templates" > /dev/null 2>&1; then \
				printf "Passed $${example}\n"; \
			else \
				printf "Failed $${example}. run 'make generate-examples' to re-render the example with the latest $${example}/values.yaml\n"; \
				exit 1; \
			fi; \
			rm -rf "$${EXAMPLE_TMP}" \
		); \
		echo "All examples passed for chart: $${chart_name}"; \
	done

.PHONY: update-operator-crds
update-operator-crds:
	APP_VERSION=$$(cat ./charts/opentelemetry-operator/Chart.yaml | sed -nr 's/appVersion: ([0-9]+\.[0-9]+\.[0-9]+)/\1/p') ; \
	curl -s -o ./charts/opentelemetry-operator/crds/crd-opentelemetrycollector.yaml https://raw.githubusercontent.com/open-telemetry/opentelemetry-operator/v$${APP_VERSION}/config/crd/bases/opentelemetry.io_opentelemetrycollectors.yaml ; \
	curl -s -o ./charts/opentelemetry-operator/crds/crd-opentelemetryinstrumentation.yaml https://raw.githubusercontent.com/open-telemetry/opentelemetry-operator/v$${APP_VERSION}/config/crd/bases/opentelemetry.io_instrumentations.yaml ; \
	curl -s -o ./charts/opentelemetry-operator/crds/crd-opentelemetry.io_opampbridges.yaml https://raw.githubusercontent.com/open-telemetry/opentelemetry-operator/v$${APP_VERSION}/config/crd/bases/opentelemetry.io_opampbridges.yaml

.PHONY: check-operator-crds
check-operator-crds:
	APP_VERSION=$$(cat ./charts/opentelemetry-operator/Chart.yaml | sed -nr 's/appVersion: ([0-9]+\.[0-9]+\.[0-9]+)/\1/p'); \
	mkdir -p ${TMP_DIRECTORY}/crds; \
	curl -s -o "${TMP_DIRECTORY}/crds/crd-opentelemetrycollector.yaml" https://raw.githubusercontent.com/open-telemetry/opentelemetry-operator/v$${APP_VERSION}/config/crd/bases/opentelemetry.io_opentelemetrycollectors.yaml; \
	curl -s -o "${TMP_DIRECTORY}/crds/crd-opentelemetryinstrumentation.yaml" https://raw.githubusercontent.com/open-telemetry/opentelemetry-operator/v$${APP_VERSION}/config/crd/bases/opentelemetry.io_instrumentations.yaml; \
	curl -s -o "${TMP_DIRECTORY}/crds/crd-opentelemetry.io_opampbridges.yaml" https://raw.githubusercontent.com/open-telemetry/opentelemetry-operator/v$${APP_VERSION}/config/crd/bases/opentelemetry.io_opampbridges.yaml; \
	if diff ${TMP_DIRECTORY}/crds ./charts/opentelemetry-operator/crds > /dev/null; then \
		echo "Passed"; \
		rm -rf ${TMP_DIRECTORY}; \
	else \
		echo "Failed. run 'make update-operator-crds' to update the crds"; \
		rm -rf ${TMP_DIRECTORY}; \
		exit 1; \
	fi; \

.PHONY: validate-examples
validate-examples:
	cd charts/opentelemetry-collector && ./validate-configs.sh

.PHONY: validate-version-bump
validate-version-bump:
	./charts/opentelemetry-collector/validate-chart-version-bump.sh
