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

- `features: [application]` emits all four body-size histograms. To keep the latency
  histograms and drop the body sizes, use `features: [application_red]`; `application_sizes`
  selects the body sizes alone.
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

## Network metrics

`presets.networkMetrics.enabled: true` exports node-wide network metrics between Kubernetes
workloads (see
[examples/ebpf-instrumentation-network-metrics](./examples/ebpf-instrumentation-network-metrics/values.yaml)).
It works with either `preset`: network flows and TCP stats are captured for every socket on the
node, not only for the instrumented processes. The DaemonSet runs with `hostNetwork` and mounts
tracefs.

| Metric (OTLP name) | Feature | Attributes |
| --- | --- | --- |
| `obi.network.flow.bytes` | `network` | `direction`, `k8s.{src,dst}.owner.{name,type}`, `k8s.{src,dst}.namespace`, `k8s.cluster.name` |
| `obi.network.inter.zone.bytes` | `network_inter_zone` | `{src,dst}.zone`, `k8s.{src,dst}.owner.name`, `k8s.{src,dst}.namespace`, `k8s.cluster.name` |
| `obi.stat.tcp.rtt` | `stats_tcp_rtt` | `k8s.{src,dst}.owner.{name,type}`, `k8s.{src,dst}.namespace`, `k8s.cluster.name` |
| `obi.stat.tcp.failed.connections` | `stats_tcp_failed_connections` | as `obi.stat.tcp.rtt`, plus `reason` and `network.tcp.handshake.role` |
| `obi.stat.tcp.successful.connections` | `stats_tcp_successful_connections` | as `obi.stat.tcp.rtt`, plus `network.tcp.handshake.role` |
| `obi.stat.tcp.retransmits` | `stats_tcp_retransmits` | as `obi.stat.tcp.rtt` |

Things to know:

- Cardinality is bounded by the number of communicating workload pairs. IP addresses, ports and
  Pod names are left out, since their values are unbounded or churn with every rollout; this
  includes the `src.address` / `dst.address` that OBI reports on stat metrics by default.
- Peers outside the cluster have no owner, so all their traffic is reported under empty
  `k8s.dst.*` attributes.
- Stat metrics are reported from the local socket's side, so `src` is always the workload on the
  reporting node. When both ends run on nodes with OBI, each end reports the connection.
- `stats_tcp_io` is not part of the preset: it fires on every TCP send and receive, at a far
  higher event volume than the other stat metrics, and largely duplicates the flow bytes.
  `stats.enabled: true` adds it, as part of the `stats` feature.
- To change the attributes of a metric, set `config.data.attributes.select.<metric>` using the
  section names `obi.network.flow`, `obi.network.inter.zone`, `obi.stat.tcp.rtt`,
  `obi.stat.tcp.failed.connections`, `obi.stat.tcp.successful.connections` and
  `obi.stat.tcp.retransmits`. The preset leaves a section
  that is already set untouched. A section set under another spelling of the same metric (e.g.
  `obi_stat_tcp_rtt_seconds`) is merged with the preset's by OBI instead.

### Other configuration options

The [values.yaml](./values.yaml) file contains information about all other configuration
options for this chart.
