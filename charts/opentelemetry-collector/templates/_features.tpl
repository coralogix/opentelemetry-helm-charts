{{/*
Build the values used to render one collector from integration-level features.

The parent chart supplies global.coralogix.features and assigns integration.role.
Each collector expands only the parts of a feature that belong to its role.
*/}}
{{- define "opentelemetry-collector.effectiveValues" -}}
{{- $values := deepCopy .Values -}}
{{- $coralogix := get ($values.global | default dict) "coralogix" | default dict -}}
{{- $features := get $coralogix "features" | default dict -}}
{{- $role := get ($values.integration | default dict) "role" | default "" -}}

{{- $resourceCatalog := get $features "resourceCatalog" | default dict -}}
{{- $tailSampling := get $features "tailSampling" | default dict -}}
{{- $profiling := get $features "profiling" | default dict -}}
{{- $hasEnabledFeature := or (eq (get $resourceCatalog "enabled") true) (eq (get $tailSampling "enabled") true) (eq (get $profiling "enabled") true) -}}
{{- if and $hasEnabledFeature (empty $role) -}}
  {{- fail "integration.role must be set when a global Coralogix feature is enabled" -}}
{{- end -}}

{{- if eq (get $resourceCatalog "enabled") true -}}
  {{- if eq $role "agent" -}}
    {{- $_ := set $values.presets.hostMetrics "enabled" true -}}
    {{- $_ := set $values.presets.hostEntityEvents "enabled" true -}}
  {{- else if eq $role "cluster" -}}
    {{- $_ := set $values.presets.kubernetesResources "enabled" true -}}
  {{- end -}}
{{- end -}}

{{- if eq (get $tailSampling "enabled") true -}}
  {{- if eq $role "agent" -}}
    {{- $_ := set $values.presets.loadBalancing "enabled" true -}}
    {{- $_ := set $values.presets.batch "enabled" true -}}
    {{- if empty $values.presets.loadBalancing.hostname -}}
      {{- $_ := set $values.presets.loadBalancing "hostname" (get $tailSampling "gatewayEndpoint" | default "coralogix-opentelemetry-gateway") -}}
    {{- end -}}
    {{- $pipelines := $values.presets.coralogixExporter.pipelines | default (list "all") -}}
    {{- if has "all" $pipelines -}}
      {{- $pipelines = list "metrics" "logs" "profiles" -}}
    {{- else -}}
      {{- $pipelines = without $pipelines "traces" -}}
    {{- end -}}
    {{- $_ := set $values.presets.coralogixExporter "pipelines" $pipelines -}}
  {{- else if eq $role "gateway" -}}
    {{- $processors := $values.config.processors | default dict -}}
    {{- if not (hasKey $processors "tail_sampling") -}}
      {{- $_ := set $processors "tail_sampling" (dict "policies" (get $tailSampling "policies" | default list)) -}}
      {{- $_ := set $values.config "processors" $processors -}}
    {{- end -}}
    {{- $tracesPipeline := $values.config.service.pipelines.traces -}}
    {{- $_ := set $tracesPipeline "processors" (append ($tracesPipeline.processors | default list) "tail_sampling" | uniq) -}}
  {{- end -}}
{{- end -}}

{{- if eq (get $profiling "enabled") true -}}
  {{- if eq $role "agent" -}}
    {{- $_ := set $values.presets.profilesCollection "enabled" true -}}
    {{- $_ := set $values.presets.profilesK8sAttributes "enabled" true -}}
  {{- else if eq $role "profiler" -}}
    {{- $_ := set $values.presets.ebpfProfiler "enabled" true -}}
    {{- $_ := set $values.presets.otlpExporter "enabled" true -}}
    {{- $_ := set $values.presets.otlpExporter "pipelines" (list "profiles") -}}
    {{- if empty $values.presets.otlpExporter.endpoint -}}
      {{- $_ := set $values.presets.otlpExporter "endpoint" "${env:K8S_NODE_IP}:4317" -}}
    {{- end -}}
    {{- if empty $values.presets.otlpExporter.tls -}}
      {{- $_ := set $values.presets.otlpExporter "tls" (dict "insecure" true) -}}
    {{- end -}}
    {{- $_ := set $values.presets.otlpReceiver "enabled" false -}}
  {{- end -}}
{{- end -}}

{{- $values | toYaml -}}
{{- end -}}
