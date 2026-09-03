# OpenTelemetry Collector eBPF Helm Chart

The helm chart installs [OpenTelemetry eBPF Instrumentation](https://github.com/open-telemetry/opentelemetry-ebpf-instrumentation)
in kubernetes cluster.

## Installing the Chart

Add OpenTelemetry Helm repository:

```console
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
```

To install the chart with the release name my-opentelemetry-ebpf, run the following command:

```console
helm install my-opentelemetry-ebpf-instrumentation open-telemetry/opentelemetry-ebpf-instrumentation
```

## Metric features

`metrics.features` controls which groups of metrics OBI exports (rendered as the top-level
`metrics.features` in OBI's configuration, which applies to every metrics exporter — OTLP and
Prometheus alike). The chart defaults it to `[]`, disabling OBI's **application metrics**: RED
metrics for every instrumented service (`http.server.request.duration`, `rpc.*`, `db.client.*`,
`messaging.*`) plus the four `http.{server,client}.{request,response}.body.size` histograms.

Why off by default: the collector's `presets.spanMetrics` preset derives RED metrics
(`duration_ms`, `calls`) from the very same OBI traces. The metric names and units differ, so the
two sets never collide on a dashboard — but they carry the same information about the same
requests, measured and paid for twice. Traces and context propagation are completely unaffected —
features gate the metrics exporters only. The `presets.runtimeMetrics` preset (enabled by
default) appends its `application_runtime` feature on top, so a default install exports
`metrics.features: [application_runtime]`.

### Re-enabling OBI's application metrics

```yaml
metrics:
  features: [application]
```

Do this when the collector does not run `presets.spanMetrics`, or when you want OBI's semconv
metrics regardless of the duplicated ingestion (e.g. dashboards built on the `http_*`/`rpc_*`
names, or the body-size histograms, which have no spanmetrics counterpart).

Things to know:

- There is no feature-level way to keep the latency histograms and drop only the body sizes:
  `features: [application]` emits all four body-size histograms. To split them, filter the
  OTLP names `http.{server,client}.{request,response}.body.size` with a collector `filter`
  processor (the `_bytes`/`_By` underscore forms exist only after backend translation).
- `stats.enabled` and `presets.runtimeMetrics` append their own features (`stats`,
  `application_runtime`) on top of `metrics.features`. Disable those toggles too for a literal
  `features: []` (see
  [examples/ebpf-instrumentation-no-app-metrics](./examples/ebpf-instrumentation-no-app-metrics/values.yaml)).
- Precedence: a `config.data.otel_metrics_export.features` passthrough (OBI's deprecated
  per-exporter key — the only customization path in chart versions before `metrics.features`
  existed), when present, wins over `metrics.features` and renders exactly as it always did, so
  upgrades don't silently change customized installs; migrate it to `metrics.features`.
  `metrics.features` replaces a `config.data.metrics.features` passthrough. Unlike the deprecated
  passthrough, an explicit `[]` here survives templating and value merging.
- OBI silently ignores unknown feature names. OBI logs the enabled features at startup — as a
  numeric bitmask up to and including v0.12.2, by name on newer images — check the DaemonSet
  logs to verify the value actually took effect.

### Other configuration options

The [values.yaml](./values.yaml) file contains information about all other configuration
options for this chart.
