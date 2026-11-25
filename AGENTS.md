# AGENTS instructions for Codex contributors

These rules apply to the entire repository when working through the Codex web UI.

## Scope of changes

* Keep chart-related modifications confined to the `charts/opentelemetry-collector` directory.
* If you update the collector image, bump the chart's **minor** version (for example, `0.119.x` → `0.120.0`).

## Release hygiene (exactly once per PR/branch)

Whenever you make a change that will ship with the chart, you **must** perform the following release steps before the PR is finalized. Do them exactly once per PR/branch—do **not** bump the version multiple times within the same change set.

1. Bump the chart version in `charts/opentelemetry-collector/Chart.yaml`.
2. Add a consolidated entry for that version to `charts/opentelemetry-collector/CHANGELOG.md` using the format described below.
3. Regenerate any derived values and examples so the repository reflects the new defaults:
   * Update `charts/opentelemetry-collector/values.yaml` and `charts/opentelemetry-collector/values.schema.json` as needed.
   * Run `make generate-examples CHARTS=opentelemetry-collector` and include the refreshed manifests.
4. Commit the code changes together with the version bump, changelog entry, updated values, and regenerated examples.

## Updating the changelog

* Add the new entry to `charts/opentelemetry-collector/CHANGELOG.md`.
* Use the current date in `YYYY-MM-DD` format (retrieve it with `date +%Y-%m-%d`).
* Mirror the structure of the upstream opentelemetry-collector changelog.
* Follow the heading format `### vX.Y.Z / YYYY-MM-DD`.

### Additional guidelines

* Write a single consolidated changelog entry covering all changes included in the version.
* Only bump the chart version once per PR/branch to avoid duplicate changelog entries.

## Writing presets

Presets are the product surface for enterprise customers: they turn one `enabled: true` into
a complete, working configuration with sensible defaults. Prefer presets that work out of the
box and stay readable, over flexible machinery.

* Write the preset's collector config as literal declarative YAML inside its `...Config`
  define in `templates/_config.tpl`. A reviewer (or an agent) must be able to read the final
  config straight from the template — each component block guarded by a plain
  `{{- if $cp.component.enabled }}`, with a one-line comment stating what it targets and why.
* Do NOT build component config with code: no `$receivers := dict` populated with `set`/
  `append` and then serialized, no parametric helpers that render receiver YAML from dict
  arguments, no dict-of-regex keep-lists or `printf`-assembled fragments. We deliberately
  avoid these "magic dicts": they hide the final config behind a layer of Helm code, which
  makes review hard and surprises customers. Duplicating two similar blocks literally is
  always preferable to one clever helper.
* The established patterns stay: pipeline wiring via `set`/`append | uniq` in `apply<Preset>`,
  `mustMergeOverwrite (include "...Config" | fromYaml) .config` so user `config` always wins,
  small scalar locals, validation defines that `fail` with a clear `[ERROR]` message.
* Hide complexity behind values, not templates: keep the values surface small and flat — an
  `enabled` flag per component plus simple scalars (interval, endpoint). Anything more
  advanced goes through the `config` deep-merge escape hatch, which always wins over preset
  defaults. See `presets.dbMonitoring.postgresql` in the telemetry-shippers otel-integration
  repo for the consumer-side pattern.
* Always expose an `enabled: false` default so customers opt in explicitly; validate at render
  time and `fail` with a `[ERROR] presets.<name>...` message when prerequisites are missing.

Good (literal, readable): the `prometheus/scheduler:` block written out under
`{{- if $cp.scheduler.enabled }}` — see `k8sControlPlaneMetricsConfig` in `templates/_config.tpl`
for the reference implementation.

Bad (magic dicts): `$receivers := dict` filled via a `controlPlaneReceiver`-style helper and
`set`, then serialized — see commit 424330086 for the rejected shape.

## Shippers repository changes

* Do not create a separate PR in the `telemetry-shippers` repository for chart version bumps; shippers receives those updates automatically.
* Create a shippers PR only when the change also requires modifying shippers-specific `values.yaml` or other YAML configuration.
