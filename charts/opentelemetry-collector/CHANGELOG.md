# Changelog

## OpenTelemetry Collector

### v0.71.3 / 2023-10-04

- [FIX] hostmetrics don't scrape /run/containerd/runc/* for filesystem metrics

### v0.71.2 / 2023-09-13

- Add metadata preset, to allow users add k8s.cluster.name and cx.otel_integration.name

### v0.71.1 / 2023-09-04

- Fix nodeSelector, affinity and tolerations CRD Generation