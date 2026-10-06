# Database semantic convention compatibility tests

Install Python 3 with PyYAML and Helm. From the repository root, run the rendering regression checks:

```sh
python3 charts/opentelemetry-collector/tests/db-deprecated-semconv.py
```

This covers 48 combinations: both span metric presets, deployment/daemonset modes, omitted/disabled/enabled compatibility, and independently enabled DB/compact pipelines. It also verifies the exact 13 statements and processor ordering.

To send real legacy OTLP spans through the rendered DB processor/connector chains in an isolated Kubernetes cluster:

```sh
kind create cluster --name db-semconv-test
python3 charts/opentelemetry-collector/tests/db-deprecated-semconv.py \
  --context kind-db-semconv-test --output /tmp/db-semconv-results
kind delete cluster --name db-semconv-test
```

The test uses `otel/opentelemetry-collector-contrib:0.161.0` (matching the chart's current appVersion) and `busybox:1.37`. Override the collector image with `--image` when testing another distribution/version. Kubernetes can pull both public images; preload them for offline runs.

Each runtime case deploys the chart-rendered database processors and spanmetrics connectors, substitutes a local OTLP HTTP receiver and file exporters, and captures detailed DB traces and metrics. The full chart's unrelated pipelines and exporters are excluded. The test checks namespace fallback precedence, every collection mapping (including Redis integers and DynamoDB arrays), operation mapping, preservation of modern attributes, and exclusion of server/non-DB spans from compact metrics. It compares enabled versus disabled behavior for both presets. Evidence includes the original rendered config, runtime config, input spans, output traces/metrics, Collector logs, and assertion results. Pods and ConfigMaps are removed after each case, including on failure; the cluster is managed by the caller.
