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
Prometheus alike). When unset (the default), OBI falls back to its built-in default of
`[application]`: RED metrics for every instrumented service (`http.server.request.duration`,
`rpc.*`, `db.client.*`, `messaging.*`) plus the four
`http.{server,client}.{request,response}.body.size` histograms.

```yaml
metrics:
  features: []
```

An explicit empty list disables **all** OBI application metrics. Traces and context propagation
are completely unaffected — features gate the metrics exporters only.

### When to set `features: []`

Set it whenever the collector's `presets.spanMetrics` is enabled. The spanmetrics connector
derives RED metrics (`duration_ms`, `calls`) from the very same OBI traces, so keeping OBI's
default `application` feature measures — and pays for — every request twice. Note the two metric
sets are not fully equivalent: the `http.*.body.size` histograms have no spanmetrics counterpart,
and dashboards built on the semconv `http_*`/`rpc_*` names will not read the connector's
`duration_ms`/`calls` output.

Things to know:

- There is no feature-level way to keep the latency histograms and drop only the body sizes:
  `features: [application]` still emits all four body-size histograms. To split them, filter the
  OTLP names `http.{server,client}.{request,response}.body.size` with a collector `filter`
  processor (the `_bytes`/`_By` underscore forms exist only after backend translation).
- `stats.enabled` and `presets.runtimeMetrics` append their own features (`stats`,
  `application_runtime`) on top of `metrics.features`. With the default
  `presets.runtimeMetrics.enabled: true`, `features: []` renders
  `features: [application_runtime]` — usually what you want, since runtime metrics are not
  duplicated by spanmetrics (see
  [examples/ebpf-instrumentation-span-metrics](./examples/ebpf-instrumentation-span-metrics/values.yaml)).
  Disable those toggles too for a literal `features: []` (see
  [examples/ebpf-instrumentation-no-app-metrics](./examples/ebpf-instrumentation-no-app-metrics/values.yaml)).
- `metrics.features` takes precedence over the `config.data` passthroughs: it replaces
  `config.data.metrics.features` and removes a `config.data.otel_metrics_export.features` (OBI's
  deprecated per-exporter key, which would otherwise override the modern top-level one) from the
  rendered config. Unlike the deprecated passthrough, an explicit `[]` survives templating and
  value merging.
- OBI silently ignores unknown feature names. OBI logs the enabled features at startup — as a
  numeric bitmask up to and including v0.12.2, by name on newer images — check the DaemonSet
  logs to verify the value actually took effect.

### Other configuration options

The [values.yaml](./values.yaml) file contains information about all other configuration
options for this chart.
