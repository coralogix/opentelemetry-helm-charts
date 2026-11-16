{{/*
Database Monitoring (DBM) preset (EC-09). Status: development.

Pipelines (design section 8, ADR-0018):
  metrics/dbm:      postgresql/dbm_<name>_metrics -> memory_limiter -> [resource/dbm_scope] -> dbmkey -> dbentity (+ coralogix)
  logs/dbm:         postgresql/dbm_<name>_events  -> memory_limiter -> [resource/dbm_scope] -> dbmkey -> dbm -> batch/dbm -> coralogix/dbm
  logs/dbm_entity:  dbentity -> nop | coralogix/dbm_entity
  logs/dbm_file:    filelog/dbm -> memory_limiter -> dbmlogparser -> resource/dbm_file -> [resource/dbm_scope] -> dbmkey -> dbm -> filter/dbm_file_unparsed -> coralogix/dbm
                    (dbmlogparser: PostgreSQL jsonlog/csvlog entries -> one record each, EC-11; the filter drops what it did not stamp)

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
{{- $lowerNames := list }}
{{- range $dbm.instances }}
{{- if not (regexMatch "^[a-z][a-z0-9_]{0,39}$" (toString .name)) }}
{{- fail (printf "presets.databaseMonitoring.instances: name %q must match ^[a-z][a-z0-9_]{0,39}$" (toString .name)) }}
{{- end }}
{{- if or (hasKey . "password") (hasKey . "username") }}
{{- fail (printf "presets.databaseMonitoring.instances[%s]: inline username/password is not allowed; use credentialsSecret (SEC-F-19)" (toString .name)) }}
{{- end }}
{{- if not .credentialsSecret }}
{{- fail (printf "presets.databaseMonitoring.instances[%s]: credentialsSecret is required (SEC-F-19)" (toString .name)) }}
{{- end }}
{{- if has (lower .name) $lowerNames }}
{{- fail (printf "presets.databaseMonitoring.instances: duplicate name %q" .name) }}
{{- end }}
{{- $names = append $names .name }}
{{- $lowerNames = append $lowerNames (lower .name) }}
{{- end }}
{{- /* The preset owns its components: a `config:` override would replace them (mustMergeOverwrite) and
       break its guarantees (Secret-only credentials, dbmkey before dbm, fail-closed file logs). */}}
{{- $cfg := .Values.config | default dict }}
{{- $pipelines := (($cfg.service | default dict).pipelines) | default dict }}
{{- range $p := list "metrics/dbm" "logs/dbm" "logs/dbm_entity" "logs/dbm_file" }}
{{- if hasKey $pipelines $p }}
{{- fail (printf "presets.databaseMonitoring: config.service.pipelines.%s is owned by the preset; do not redefine it in config" $p) }}
{{- end }}
{{- end }}
{{- $owned := dict
    "processors" (list "dbm" "dbmkey" "dbmlogparser" "batch/dbm" "filter/dbm_file_unparsed" "resource/dbm_scope" "resource/dbm_file")
    "exporters" (list "coralogix/dbm" "coralogix/dbm_entity")
    "connectors" (list "dbentity")
    "receivers" (list "filelog/dbm") }}
{{- range $section := keys $owned | sortAlpha }}
{{- $have := (get $cfg $section) | default dict }}
{{- range $id := get $owned $section }}
{{- if hasKey $have $id }}
{{- fail (printf "presets.databaseMonitoring: config.%s.%s is owned by the preset; do not redefine it in config" $section $id) }}
{{- end }}
{{- end }}
{{- if eq $section "receivers" }}
{{- range $id := keys $have }}
{{- if hasPrefix "postgresql/dbm_" $id }}
{{- fail (printf "presets.databaseMonitoring: config.receivers.%s is owned by the preset; do not redefine it in config" $id) }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}
{{- /* The receiver.postgresql.connectionPool gate (beta, on by default in the cdot image) must stay on:
       without it the pool settings (SEC-F-17) are ignored. */}}
{{- range ((.Values.command | default dict).extraArgs | default list) }}
{{- if contains "-receiver.postgresql.connectionPool" (toString .) }}
{{- fail (printf "presets.databaseMonitoring: command.extraArgs %q disables the receiver.postgresql.connectionPool feature gate, which the DBM connection pool settings need" (toString .)) }}
{{- end }}
{{- end }}
{{- /* extraEnvs must not copy the DBM credentials into other env vars. */}}
{{- $secretNames := list }}
{{- range $dbm.instances }}{{- $secretNames = append $secretNames .credentialsSecret.name }}{{- end }}
{{- range .Values.extraEnvs | default list }}
{{- if contains "$(DBM_" (toString (.value | default "")) }}
{{- fail (printf "presets.databaseMonitoring: extraEnvs[%s] expands a DBM env var ($(DBM_...)); the DBM credentials are for the preset only" (toString .name)) }}
{{- end }}
{{- $ref := ((.valueFrom | default dict).secretKeyRef | default dict) }}
{{- if and $ref.name (has $ref.name $secretNames) }}
{{- fail (printf "presets.databaseMonitoring: extraEnvs[%s] reads the instance credentials Secret %s; the DBM credentials are for the preset only" (toString .name) $ref.name) }}
{{- end }}
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
      max_idle: {{ $dbm.connectionPool.maxIdle }}
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
      max_idle: {{ $dbm.connectionPool.maxIdle }}
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
    {{- if eq $dbm.logs.filelog.format "csvlog" }}
    # A csvlog entry spans lines when a quoted field holds a newline: an entry starts at a timestamp.
    multiline:
      line_start_pattern: '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}'
    {{- end }}
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
        {{- with .awsAccountId }}
        aws_account_id: {{ . | quote }}
        {{- end }}
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
  # EC-11: one record per PostgreSQL log entry; entries that do not parse are dropped and counted.
  dbmlogparser:
    format: {{ $dbm.logs.filelog.format }}
  # Final guard: only records the parser stamped (cx.dbm.log.parser) and dbmkey keyed
  # (cx.dbm.collector_key, without which dbm redacts nothing) reach the exporter, so no raw
  # or unredacted log line leaves the collector (ADR-0018 item 5b, fail closed).
  filter/dbm_file_unparsed:
    error_mode: propagate
    logs:
      log_record:
        - 'attributes["cx.dbm.log.parser"] == nil'
        - 'resource.attributes["cx.dbm.collector_key"] == nil'
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
      processors: {{ toJson (concat (list "memory_limiter" "dbmlogparser" "resource/dbm_file") (rest $head) (list "dbmkey" "dbm" "filter/dbm_file_unparsed")) }}
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
      key: {{ .credentialsSecret.passwordKey | default "password" | quote }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Final guard on the fully merged config (after extraConfig and the processor reordering), so no
`config:`/`extraConfig` path can route DBM data around `dbm` or change what the preset rendered.
Input: dict "config" (merged config) "expected" (the preset's own render).
*/}}
{{- define "opentelemetry-collector.dbmFinalGuard" -}}
{{- $config := .config }}
{{- $expected := .expected }}
{{- $pipelines := (($config.service | default dict).pipelines) | default dict }}
{{- $expPipelines := $expected.service.pipelines }}
{{- $ownedPipelines := keys $expPipelines | sortAlpha }}
{{- /* 1. Owned components stay where the preset put them. */}}
{{- range $name := keys $pipelines | sortAlpha }}
{{- $pl := get $pipelines $name | default dict }}
{{- if not (has $name $ownedPipelines) }}
{{- range $r := $pl.receivers | default list }}
{{- if or (hasPrefix "postgresql/dbm_" $r) (eq $r "filelog/dbm") (eq $r "dbentity") }}
{{- fail (printf "presets.databaseMonitoring: receiver %s is owned by the preset and must not be used in pipeline %s" $r $name) }}
{{- end }}
{{- end }}
{{- range $p := $pl.processors | default list }}
{{- if has $p (list "dbm" "dbmkey" "dbmlogparser" "batch/dbm" "filter/dbm_file_unparsed" "resource/dbm_scope" "resource/dbm_file") }}
{{- fail (printf "presets.databaseMonitoring: processor %s is owned by the preset and must not be used in pipeline %s" $p $name) }}
{{- end }}
{{- end }}
{{- range $e := $pl.exporters | default list }}
{{- if has $e (list "coralogix/dbm" "coralogix/dbm_entity" "dbentity") }}
{{- fail (printf "presets.databaseMonitoring: exporter %s is owned by the preset and must not be used in pipeline %s" $e $name) }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}
{{- /* 2. Owned pipelines are exactly what the preset rendered. */}}
{{- range $name := $ownedPipelines }}
{{- $want := get $expPipelines $name }}
{{- $have := get $pipelines $name | default dict }}
{{- range $field := list "receivers" "processors" "exporters" }}
{{- if ne (toJson (get $want $field | default list)) (toJson (get $have $field | default list)) }}
{{- fail (printf "presets.databaseMonitoring: service.pipelines.%s.%s is owned by the preset and must not be changed" $name $field) }}
{{- end }}
{{- end }}
{{- end }}
{{- /* 4. Only the preset's own components may read the DBM Secret env vars (DBM_*). */}}
{{- range $section := list "receivers" "processors" "exporters" "connectors" "extensions" }}
{{- $want := get $expected $section | default dict }}
{{- $have := get $config $section | default dict }}
{{- range $id := keys $have | sortAlpha }}
{{- if and (not (hasKey $want $id)) (regexMatch "\\$\\{?(env:)?DBM_" (toJson (get $have $id))) }}
{{- fail (printf "presets.databaseMonitoring: config %s.%s references the DBM Secret env vars (DBM_*); only the preset's components may use them" $section $id) }}
{{- end }}
{{- end }}
{{- end }}
{{- /* 3. Owned component configurations are exactly what the preset rendered (nop is shared and skipped). */}}
{{- range $section := list "receivers" "processors" "exporters" "connectors" }}
{{- $want := get $expected $section | default dict }}
{{- $have := get $config $section | default dict }}
{{- range $id := keys $want | sortAlpha }}
{{- if and (ne $id "nop") (ne (toJson (get $want $id)) (toJson (get $have $id))) }}
{{- fail (printf "presets.databaseMonitoring: %s.%s is owned by the preset and must not be changed" $section $id) }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}
