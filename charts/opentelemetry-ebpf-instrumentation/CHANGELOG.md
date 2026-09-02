# Changelog

## OpenTelemetry eBPF Instrumentation

### v0.1.26 / 2026-09-07

- [Feature] Add a first-class `metrics.features` value, rendered as the top-level `metrics.features` in OBI's configuration (the modern key, applying to every metrics exporter — not the deprecated per-exporter `otel_metrics_export.features`). Unset (the default) keeps today's behavior. An explicit empty list (`features: []`) disables all OBI application metrics while leaving traces and context propagation untouched — the recommended setting when the collector's `presets.spanMetrics` is enabled, since the spanmetrics connector already derives RED metrics (`duration_ms`, `calls`) from the same OBI traces and the default `application` feature would measure every request twice. The `stats.enabled` and `presets.runtimeMetrics` toggles still append their features (`stats`, `application_runtime`) on top of the list. The value takes precedence over both `config.data` feature passthroughs, removing a deprecated `config.data.otel_metrics_export.features` from the rendered config since OBI would otherwise let it override the modern key
- [Fix] The `stats.enabled` / `presets.runtimeMetrics` feature-merging now honors a `config.data.metrics.features` passthrough (OBI's modern key) as its base list and appends to that key; previously the merged list was always written to the deprecated `otel_metrics_export.features`, which OBI lets override the modern key, silently discarding such a passthrough. Configurations using the deprecated passthrough (or none) render exactly as before

### v0.1.26 / 2026-09-06

- [Change] Bump OBI image to v0.13.0
- [Fix] Note for upgraders: v0.13.0 fixes a group of memory-safety bugs in the socket-layer context propagation. The header injector no longer acts on a leftover message buffer, which could write a `traceparent` into the middle of a TLS stream and reset the instrumented connection; message-buffer reads are bounded by the mapped data window, so a failed pull no longer copies adjacent kernel memory into span payloads, and sends of 8 KiB or more are captured again. Installs running `presets.contextPropagation` should take this image
- [Change] Note for upgraders: `service.name` and `service.namespace` are no longer default metric attributes. They remain resource attributes, so the OTLP metrics this chart exports still carry the service identity and the Coralogix pipeline is unaffected. Prometheus scrapers lose the `service_name` / `service_namespace` labels on application metric series; restore them with `config.data.attributes.extra_group_attributes.app: [service.name, service.namespace]`, or join through `target_info`
- [Change] Note for upgraders: Go runtime metric probes now require the `application_runtime` feature. The `presets.runtimeMetrics` preset already adds it, so a default install keeps Go runtime metrics; installs that configure `metrics.features` by hand must include it
- [Change] Note for upgraders: `error.type` values are unified across spans and metrics, and TCP client/server roles are classified by the local port, which corrects previously swapped roles for same-namespace clients
- [Feature] The image adds runtime metrics for Python, the JVM and Node.js, Aerospike server spans, Go 1.27 support, `db.response.status_code`, `db.namespace` and `server.port` on database duration metrics, `messaging.operation.name` on messaging spans, and IPv6 reverse DNS

### v0.1.25 / 2026-08-25

- [Feature] Enable peer name resolution by default with `name_resolver.sources: [k8s, rdns]`: peer/host IPs resolve to names from the Kubernetes informer metadata and from the DNS answers OBI already captures. Both sources are in-memory and generate no lookups; the active `dns` source stays disabled since it issues blocking PTR queries from the span pipeline

### v0.1.24 / 2026-08-23

- [Feature] Add a `presets.runtimeMetrics` preset, exporting application runtime metrics (Go memory limits, completed GC cycles, GOMAXPROCS and GOGC; HotSpot JVM heap used/committed/limit; Node.js event loop). It is enabled by default for every language OBI supports, adding the `application_runtime` metrics feature. `presets.runtimeMetrics.languages` narrows it to a list of detected languages, named as OBI names them, by giving every `discovery.instrument` selector a language-scoped copy carrying the feature, so it never widens the set of instrumented processes; a selector that already sets `languages` is left untouched. Note that Node.js runtime metrics are collected by injecting a JavaScript agent into every discovered Node.js process through the Node.js inspector, and that agent writes progress lines to the process' own stdout: `languages: [go, java]` leaves Node.js processes alone, and `nodejs.enabled: false` turns the injector off entirely
- [Change] The `runtimeMetrics.go.enabled` / `runtimeMetrics.jvm.enabled` values are replaced by `presets.runtimeMetrics`, and runtime metrics are now exported by default. `runtimeMetrics.jvm.samplingInterval` moves to `presets.runtimeMetrics.jvm.samplingInterval`. The previous per-language split was cosmetic: both flags mapped to the single `application_runtime` feature, and the `jvm_runtime_metrics.enabled` key the chart rendered does not exist in the OBI configuration
- [Feature] Add a `presets.logEnricher` preset, injecting the active trace context into the logs written by the instrumented processes. It is disabled by default; enabling it enriches the workloads selected by `config.data.discovery.instrument`, and `presets.logEnricher.plainText.enabled: false` keeps the enrichment to JSON logs only, leaving plain-text output untouched
- [Fix] Enabling `stats` no longer drops application metrics. The chart appended `stats` to an empty feature list, rendering `features: [stats]`, which replaced the OBI default of `[application]`

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
