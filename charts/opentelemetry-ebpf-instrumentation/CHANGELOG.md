# Changelog

## OpenTelemetry eBPF Instrumentation

### v0.1.23 / 2026-08-22

- [Change] Bump OBI image to v0.12.2
- [Fix] `runtimeMetrics.jvm.enabled` now adds the `application_runtime` metrics feature instead of `application_jvm`. The `application_jvm` alias was removed in OBI v0.11.0, so on the new image the previous value produced an unknown feature
- [Change] Note for upgraders: plain-text log enrichment is enabled by default in OBI v0.11.0 and later for every service the log enricher selects, appending space-separated `trace_id=` / `span_id=` fields to non-JSON writes. The chart does not enable the log enricher, so a default install is unaffected; installs that turn it on through `config` can restore the previous behavior with `ebpf.log_enricher.plain_text.enabled: false`
- [Change] Note for upgraders: server-side Redis and Memcached measurements now report `db.server.operation.duration` instead of `db.client.operation.duration`

### v0.1.22 / 2026-08-18

- [Feature] Add a `presets.annotationFilter` preset, restricting the instrumented workloads by Kubernetes Pod annotation. Enabling it instruments only the Pods annotated `obi.coralogix.com/enabled: "true"`; `mode: exclude` instead skips the Pods annotated `obi.coralogix.com/enabled: "false"`

### v0.1.21 / 2026-08-18

- [Fix] Scope the attribute `select` to the `traces` section and include all attributes, instead of adding `gen_ai.*` under `'*'`. The previous `'*'` selector applied to metrics too and, being a non-empty include, replaced the default metric/span attribute set — dropping defaults such as `url.query` from spans. Spans now carry all optional attributes (GenAI payloads included) while metric attributes stay at their defaults.

### v0.1.20 / 2026-08-18

- [Fix] Only configure `prometheus_export` when `service.enabled` is set. OBI expires Prometheus metric children only while serving a scrape, so the previous default (endpoint configured, with no Service and no ServiceMonitor) retained every series for the lifetime of the process. The container port follows the same condition.

### v0.1.19 / 2026-08-18

- [Fix] ServiceMonitor now honours `serviceMonitor.metrics.endpoint`; the template read `serviceMonitor.endpoint`, so the scrape settings were silently dropped
- [Fix] Mount `/sys/kernel/tracing` whenever context propagation is enabled, not only when `stats.enabled` — the default deployment mounted no tracefs at all
- [Fix] Grant `NET_ADMIN` and mount `/sys/fs/cgroup` for the `network` preset, not only when context propagation is enabled
- [Fix] Container ports no longer render empty or duplicated when `prometheus_export.port` / `internal_metrics.prometheus.port` are unset or equal to the service target ports. The Service, ServiceMonitor and DaemonSet now resolve the effective metrics / internal-metrics ports the same way before comparing them, which also fixes the internal-metrics port being dropped whenever neither `targetPort` override was set
- [Change] The `cgroup` and `tracefs` hostPath volumes now declare `type: Directory`; on a node where the path does not exist the Pod stays `Pending` with a clear event instead of starting with a silently empty mount
- [Feature] Render `podAnnotations` through `tpl`, so they can reference release values
- [Chore] Exclude `tests/` and `examples/` from the packaged chart, and document the `annotations`, `initContainers`, `service.nodePort`, `service.externalIPs`, `service.externalTrafficPolicy` and `service.internalMetrics.nodePort` values the templates already support

### v0.1.18 / 2026-07-01

- [Change] Bump OBI image to v0.10.0
- [Fix] Update default `contextPropagation.mode` from "http,tcp" to "headers,tcp" (the "http" alias was removed upstream and now causes a startup error)
- [Fix] Fix typo in default config: `payload_extraction.http.genai.rerank` (was `rereank`)
- [Feature] Add `runtimeMetrics.go.enabled` and `runtimeMetrics.jvm.enabled` options (both default `false`) to opt in to the new Go and JVM application runtime metrics
- [Feature] Add `health_check.port` (default `0`/disabled) to the default OBI config to surface the new pipeline health-check endpoint
- [Fix] `stats.enabled: true` now also adds the "stats" metrics feature to `otel_metrics_export.features`; previously it only mounted tracefs, so stat probes loaded as no-op stubs and no stats metrics were ever exported
- [Fix] Migrate default discovery config from deprecated `services`/`exclude_services` to `instrument`/`exclude_instrument` with glob syntax
- [Fix] Fix default `k8s_namespace` pattern from `.` (matches any single character) to `"*"` (glob for any namespace)

### v0.1.17 / 2026-06-08

- [Feature] Add Stat metrics option to OBI config, defaults false

### v0.1.16 / 2026-05-14

- [Chore] Bump version to v0.1.15.
- [Change] Update configurations with GenAI + jsonrpc + kafka instrumentations

### v0.1.15 / 2026-04-09

- [Chore] Bump version to v0.1.15.

### v0.1.14 / 2026-03-09
- [Change] Bump OBI image to v0.7.1

### v0.1.13 / 2026-04-05
- [Change] Bump OBI image to v0.7.0

### v0.1.12 / 2026-03-09
- [Change] Bump OBI image to v0.6.0

### v0.1.11 / 2026-02-17
- [Change] Bump OBI image to v0.5.0

### v0.1.10 / 2026-01-12
- [Change] Bump OBI image to v0.4.1

### v0.1.9 / 2025-12-15
- [Feature] Add Context Propagation Mode option to OBI config, defaults to "http,tcp"

### v0.1.8 / 2025-12-04
- [Change] Bump OBI image to v0.3.0
- [Fix] Get image tag from appVersion in Chart.yaml

### v0.1.7 / 2025-12-02
- [Change] Bump OBI image to v0.2.0
- [Fix] Fixes in OBI default config

### v0.1.6 / 2025-11-03
- [Change] Bump OBI image to v0.1.0

### v0.1.5 / 2025-10-21
- [Feat] Increase http, postgres default buffer sizes, add graphql payload extraction

### v0.1.4 / 2025-08-11
- [Fix] add toleration, affinity and nodeSelector to k8s cache deployment

### v0.1.3 / 2025-08-04
- [Fix] Fix redis db cache enable to enabled

### v0.1.2 / 2025-07-13
- [Feat] Add context propagation value in `values.yaml` ([port from beyla](https://github.com/grafana/beyla/commit/37749b58ef616bbb304216ee5407ba95bae9c6fb))
- [Feat] Change default values to add redis db cache, k8s cache and mysql large buffers
- [Feat] Change default of attributes.kubernetes.enabled to true

### v0.1.1 / 2025-06-17
- [Feat] Use new `otel/opentelemetry-ebpf-k8s-cache` image instead of beyla one
- [Fix] rename `otel-ebpf-k8s-cache` to `opentelemetry-ebpf-instrumentation-k8s-cache`

### v0.1.0 / 2025-06-15
- [Feat] New chart for OpenTelemetry eBPF Instrumentation
