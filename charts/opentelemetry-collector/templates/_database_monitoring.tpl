{{/*
Database Monitoring (DBM) preset (EC-09). Status: development.

Pipelines (design section 8, ADR-0018):
  metrics/dbm:      postgresql/dbm_<name>_metrics -> memory_limiter -> [resource/dbm_scope] -> dbmkey -> dbentity (+ coralogix)
  logs/dbm:         postgresql/dbm_<name>_events  -> memory_limiter -> [resource/dbm_scope] -> dbmkey -> dbm -> batch/dbm -> coralogix/dbm
  logs/dbm_entity:  dbentity -> nop | coralogix/dbm_entity
  logs/dbm_file:    filelog/dbm -> memory_limiter -> resource/dbm_file -> [resource/dbm_scope] -> dbmkey -> dbm -> filter/dbm_file_unparsed -> coralogix/dbm

Credentials come only from a Kubernetes Secret, through env vars (SEC-F-19).
*/}}

{{/* Env var prefix of one instance: DBM_<NAME>. */}}
{{- define "opentelemetry-collector.dbmEnvPrefix" -}}
{{- printf "DBM_%s" (upper .name) -}}
{{- end }}

{{/* Fails on any value combination the preset refuses. */}}
{{- define "opentelemetry-collector.dbmValidate" -}}
{{- $dbm := .Values.presets.databaseMonitoring }}
{{- if .Values.collectorCRD.generate }}
{{- fail "presets.databaseMonitoring: collectorCRD.generate is not supported (credentials are injected as pod env from Secrets)" }}
{{- end }}
{{- if not (or (eq .Values.mode "deployment") (eq .Values.mode "statefulset")) }}
{{- fail "presets.databaseMonitoring: mode must be deployment or statefulset (design topology 2)" }}
{{- end }}
{{- if not $dbm.instances }}
{{- fail "presets.databaseMonitoring: at least one entry in instances is required" }}
{{- end }}
{{- $names := list }}
{{- range $dbm.instances }}
{{- if or (hasKey . "password") (hasKey . "username") }}
{{- fail (printf "presets.databaseMonitoring.instances[%s]: inline username/password is not allowed; use credentialsSecret (SEC-F-19)" (toString .name)) }}
{{- end }}
{{- if not .credentialsSecret }}
{{- fail (printf "presets.databaseMonitoring.instances[%s]: credentialsSecret is required (SEC-F-19)" (toString .name)) }}
{{- end }}
{{- if has .name $names }}
{{- fail (printf "presets.databaseMonitoring.instances: duplicate name %q" .name) }}
{{- end }}
{{- $names = append $names .name }}
{{- end }}
{{- if not ($dbm.exporter.domain | default .Values.global.domain) }}
{{- fail "presets.databaseMonitoring: exporter.domain or global.domain is required" }}
{{- end }}
{{- if $dbm.rdsLogs.enabled }}
{{- fail "presets.databaseMonitoring.rdsLogs: the RDS log-file receiver (EC-12) is not available in this chart version" }}
{{- end }}
{{- if $dbm.logs.enabled }}
{{- if not $dbm.logs.filelog.include }}
{{- fail "presets.databaseMonitoring.logs: filelog.include must list at least one path" }}
{{- end }}
{{- if not (has $dbm.logs.filelog.instance $names) }}
{{- fail "presets.databaseMonitoring.logs: filelog.instance must name an entry of instances" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "opentelemetry-collector.applyDatabaseMonitoringConfig" -}}
{{- include "opentelemetry-collector.dbmValidate" .Values }}
{{- $config := mustMergeOverwrite (include "opentelemetry-collector.databaseMonitoringConfig" .Values | fromYaml) .config }}
{{- $config | toYaml }}
{{- end }}

{{- define "opentelemetry-collector.databaseMonitoringConfig" -}}
{{- $dbm := .Values.presets.databaseMonitoring }}
{{- $scope := ne ($dbm.clusterUid | default "") "" }}
{{- $metricsReceivers := list }}
{{- $eventsReceivers := list }}
{{- range $dbm.instances }}
{{- $metricsReceivers = append $metricsReceivers (printf "postgresql/dbm_%s_metrics" .name) }}
{{- $eventsReceivers = append $eventsReceivers (printf "postgresql/dbm_%s_events" .name) }}
{{- end }}
{{- $head := list "memory_limiter" }}
{{- if $scope }}{{- $head = append $head "resource/dbm_scope" }}{{- end }}
{{- $metricsExporters := list "dbentity" }}
{{- if .Values.presets.coralogixExporter.enabled }}{{- $metricsExporters = append $metricsExporters "coralogix" }}{{- end }}
receivers:
{{- range $dbm.instances }}
{{- $env := include "opentelemetry-collector.dbmEnvPrefix" . }}
{{- $tls := .tls | default dict }}
  postgresql/dbm_{{ .name }}_metrics:
    endpoint: {{ .endpoint | quote }}
    transport: tcp
    username: "${env:{{ $env }}_USERNAME}"
    password: "${env:{{ $env }}_PASSWORD}"
    databases: {{ toJson .databases }}
    collection_interval: {{ $dbm.metrics.collectionInterval }}
    connection_pool:
      max_open: {{ $dbm.connectionPool.maxOpen }}
    tls:
      insecure: {{ $tls.insecure | default false }}
      insecure_skip_verify: {{ $tls.insecureSkipVerify | default false }}
      {{- with $tls.caFile }}
      ca_file: {{ . | quote }}
      {{- end }}
    events:
      db.server.query_sample:
        enabled: false
      db.server.top_query:
        enabled: false
    metrics:
      postgresql.blocks_read:
        enabled: false
      postgresql.index.scans:
        enabled: false
      postgresql.index.size:
        enabled: false
      postgresql.operations:
        enabled: false
      postgresql.rows:
        enabled: false
      postgresql.sequential_scans:
        enabled: false
      postgresql.table.size:
        enabled: false
      postgresql.table.vacuum.count:
        enabled: false
  postgresql/dbm_{{ .name }}_events:
    endpoint: {{ .endpoint | quote }}
    transport: tcp
    username: "${env:{{ $env }}_USERNAME}"
    password: "${env:{{ $env }}_PASSWORD}"
    databases: {{ toJson .databases }}
    collection_interval: {{ $dbm.events.querySampleInterval }}
    connection_pool:
      max_open: {{ $dbm.connectionPool.maxOpen }}
    tls:
      insecure: {{ $tls.insecure | default false }}
      insecure_skip_verify: {{ $tls.insecureSkipVerify | default false }}
      {{- with $tls.caFile }}
      ca_file: {{ . | quote }}
      {{- end }}
    events:
      db.server.query_sample:
        enabled: true
      db.server.top_query:
        enabled: true
    query_sample_collection:
      max_rows_per_query: {{ $dbm.events.maxRowsPerQuery }}
    top_query_collection:
      collection_interval: {{ $dbm.events.topQueryInterval }}
      top_n_query: {{ $dbm.events.topNQuery }}
      max_rows_per_query: {{ $dbm.events.maxRowsPerQuery }}
      max_explain_each_interval: {{ $dbm.events.maxExplainEachInterval }}
{{- end }}
{{- if $dbm.logs.enabled }}
  filelog/dbm:
    include: {{ toJson $dbm.logs.filelog.include }}
    start_at: {{ $dbm.logs.filelog.startAt }}
    include_file_path: true
{{- end }}
connectors:
  dbentity:
    interval: {{ $dbm.entity.interval }}
    probe_timeout: {{ $dbm.entity.probeTimeout }}
    targets:
{{- range $dbm.instances }}
{{- $env := include "opentelemetry-collector.dbmEnvPrefix" . }}
      - endpoint: {{ .endpoint | quote }}
        db_system: postgresql
        username: "${env:{{ $env }}_USERNAME}"
        password: "${env:{{ $env }}_PASSWORD}"
        database: {{ first .databases | quote }}
        sslmode: {{ .sslmode | default "verify-full" }}
        {{- with .sslrootcert }}
        sslrootcert: {{ . | quote }}
        {{- end }}
        aws_account_id: {{ .awsAccountId | default "" | quote }}
{{- end }}
processors:
  {{- if $scope }}
  resource/dbm_scope:
    attributes:
      - key: k8s.cluster.uid
        value: {{ $dbm.clusterUid | quote }}
        action: insert
  {{- end }}
  dbmkey:
    db_system: postgresql
  dbm:
    opamp: {{ $dbm.policy.opamp | quote }}
    allow_literal_capture: {{ $dbm.policy.allowLiteralCapture }}
    lease_copy_enabled: false
    static_policy:
      mode: {{ $dbm.policy.mode }}
      top_k: {{ $dbm.policy.topK }}
      samples_per_signature_per_hour: {{ $dbm.policy.samplesPerSignaturePerHour }}
  batch/dbm:
    send_batch_size: 1024
    timeout: 5s
  {{- if $dbm.logs.enabled }}
  {{- $inst := dict }}
  {{- range $dbm.instances }}{{- if eq .name $dbm.logs.filelog.instance }}{{- $inst = . }}{{- end }}{{- end }}
  {{- $hp := splitList ":" $inst.endpoint }}
  resource/dbm_file:
    attributes:
      - key: db.system.name
        value: postgresql
        action: upsert
      - key: server.address
        value: {{ first $hp | quote }}
        action: upsert
      - key: server.port
        value: {{ last $hp | int }}
        action: upsert
      - key: dbm.log.format
        value: {{ $dbm.logs.filelog.format | quote }}
        action: upsert
  # EC-11 replaces this filter with the jsonlog/csvlog parser and edge redaction (ADR-0018 item 5b).
  # Until then no raw log line leaves the collector.
  filter/dbm_file_unparsed:
    error_mode: propagate
    logs:
      log_record:
        - "true"
  {{- end }}
exporters:
  coralogix/dbm:
    timeout: "30s"
    private_key: {{ $dbm.exporter.privateKey | quote }}
    domain: {{ $dbm.exporter.domain | default .Values.global.domain | quote }}
    application_name: "dbm"
    subsystem_name: "events"
    logs:
      headers:
        X-Coralogix-Distribution: "{{ include "opentelemetry-collector.coralogixDistribution" (dict "distribution" .Values.distribution "version" .Values.global.version) }}"
        x-coralogix-ingress: "dbm-as-otlp-logs/v1"
  {{- if $dbm.entity.export.enabled }}
  coralogix/dbm_entity:
    timeout: "30s"
    private_key: {{ $dbm.exporter.privateKey | quote }}
    domain: {{ $dbm.exporter.domain | default .Values.global.domain | quote }}
    application_name: "resource"
    subsystem_name: "catalog"
    logs:
      headers:
        X-Coralogix-Distribution: "{{ include "opentelemetry-collector.coralogixDistribution" (dict "distribution" .Values.distribution "version" .Values.global.version) }}"
        x-coralogix-ingress: "metadata-as-otlp-logs/v1"
  {{- else }}
  nop: {}
  {{- end }}
service:
  pipelines:
    metrics/dbm:
      receivers: {{ toJson $metricsReceivers }}
      processors: {{ toJson (concat $head (list "dbmkey")) }}
      exporters: {{ toJson $metricsExporters }}
    logs/dbm:
      receivers: {{ toJson $eventsReceivers }}
      processors: {{ toJson (concat $head (list "dbmkey" "dbm" "batch/dbm")) }}
      exporters: ["coralogix/dbm"]
    logs/dbm_entity:
      receivers: ["dbentity"]
      exporters: [{{ if $dbm.entity.export.enabled }}"coralogix/dbm_entity"{{ else }}"nop"{{ end }}]
    {{- if $dbm.logs.enabled }}
    logs/dbm_file:
      receivers: ["filelog/dbm"]
      processors: {{ toJson (concat (list "memory_limiter" "resource/dbm_file") (rest $head) (list "dbmkey" "dbm" "filter/dbm_file_unparsed")) }}
      exporters: ["coralogix/dbm"]
    {{- end }}
{{- end }}

{{/* Pod env: credentials of every instance from its Secret (SEC-F-19). */}}
{{- define "opentelemetry-collector.dbmEnv" -}}
{{- if .Values.presets.databaseMonitoring.enabled }}
{{- range .Values.presets.databaseMonitoring.instances }}
{{- $env := include "opentelemetry-collector.dbmEnvPrefix" . }}
- name: {{ $env }}_USERNAME
  valueFrom:
    secretKeyRef:
      name: {{ .credentialsSecret.name | quote }}
      key: {{ .credentialsSecret.usernameKey | default "username" | quote }}
- name: {{ $env }}_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ .credentialsSecret.name | quote }}
      key: {{ .credentialsSecret.usernameKey | default "username" | quote }}
{{- end }}
{{- end }}
{{- end }}
