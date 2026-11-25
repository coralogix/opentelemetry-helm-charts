{{/* Database pipelines use target metadata, rather than collector host metadata. */}}
{{- define "opentelemetry-collector.applyDbMonitoringConfig" -}}
{{- $root := .root }}
{{- $config := .config }}
{{- $generated := dict "receivers" dict "processors" dict "exporters" dict "extensions" dict "service" (dict "pipelines" dict) }}
{{- $names := dict }}
{{- $postgresql := $root.Files.Get "config/db-monitoring/postgresql.yaml" | fromYaml }}
{{- $defaults := dict
    "port" 5432
    "connectDatabase" "postgres"
    "collectionInterval" "5m"
    "receivers" dict
    "tls" (dict "insecure" false "insecure_skip_verify" false)
    "metrics" (dict "enabled" true)
    "querySamples" (dict "enabled" false)
    "topQueries" (dict "enabled" false)
    "catalog" (dict "enabled" false)
}}
{{- range $target := $root.Values.presets.dbMonitoring.postgresql }}
{{- if hasKey $names $target.name }}
{{- fail (printf "dbMonitoring.postgresql: duplicate target name %q" $target.name) }}
{{- end }}
{{- $_ := set $names $target.name true }}
{{- $target = mustMergeOverwrite (deepCopy $defaults) (deepCopy $target) }}
{{- if not (or $target.metrics.enabled $target.querySamples.enabled $target.topQueries.enabled $target.catalog.enabled) }}
{{- continue }}
{{- end }}
{{- $intervals := dict }}
{{- if $target.metrics.enabled }}
{{- $intervals = dict "performance" $target.collectionInterval "health" $target.collectionInterval "tables" $target.collectionInterval }}
{{- end }}
{{- if $target.querySamples.enabled }}
{{- $_ := set $intervals "querySamples" $target.collectionInterval }}
{{- end }}
{{- if $target.topQueries.enabled }}
{{- $_ := set $intervals "topQueries" $postgresql.receivers.queries.top_query_collection.collection_interval }}
{{- end }}
{{- if $target.catalog.enabled }}
{{- $_ := set $intervals "details" "10m" }}
{{- $_ := set $intervals "schema" "10m" }}
{{- end }}
{{- $options := dict }}
{{- range $receiver, $interval := $intervals }}
{{- $settings := get $target.receivers $receiver | default dict }}
{{- $timing := dict "collection_interval" ($settings.collectionInterval | default $interval) }}
{{- with $settings.initialDelay }}
{{- $_ := set $timing "initial_delay" . }}
{{- end }}
{{- with $settings.timeout }}
{{- $_ := set $timing "timeout" . }}
{{- end }}
{{- $_ := set $options $receiver $timing }}
{{- end }}
{{- $credentials := dict "username" $target.username }}
{{- if hasKey $target.auth "password" }}
{{- $_ := set $credentials "password" $target.auth.password }}
{{- else }}
{{- $iam := $target.auth.aws_iam }}
{{- if $target.tls.insecure }}
{{- fail (printf "dbMonitoring.postgresql %q: AWS IAM authentication requires TLS" $target.name) }}
{{- end }}
{{- $extension := printf "aws_iam_db_auth/%s" $iam.region }}
{{- $_ := set $generated.extensions $extension (dict "region" $iam.region) }}
{{- $_ := set $credentials "db_auth" $extension }}
{{- end }}
{{- $id := printf "db_monitoring_postgresql_%s" $target.name }}
{{- $identity := printf "resource/%s" $id }}
{{- $attributes := mustMergeOverwrite (deepCopy ($target.resourceAttributes | default dict)) (dict "db.system.name" "postgresql" "server.address" $target.host "server.port" $target.port "cx.db.instance.id" $target.instanceId) }}
{{- $resource := list }}
{{- range $key, $value := $attributes }}
{{- $resource = append $resource (dict "key" $key "value" $value "action" "upsert") }}
{{- end }}
{{- $_ := set $generated.processors $identity (dict "attributes" $resource) }}
{{- $_ := set $generated.processors "batch/db_monitoring" dict }}
{{- $semconv := "transform/db_monitoring_postgresql" }}
{{- $_ := set $generated.processors $semconv $postgresql.processors.semconv }}
{{- $databases := $target.databases | default (list $target.connectDatabase) }}
{{- $host := $target.host }}
{{- if contains ":" $host }}
{{- $host = printf "[%s]" $host }}
{{- end }}
{{- $native := mustMergeOverwrite (dict "endpoint" (printf "%s:%v" $host $target.port) "connect_database" $target.connectDatabase "databases" $databases "tls" $target.tls) $credentials }}
{{- $sslmode := "verify-full" }}
{{- if $target.tls.insecure }}
{{- $sslmode = "disable" }}
{{- else if $target.tls.insecure_skip_verify }}
{{- $sslmode = "require" }}
{{- end }}
{{- $params := dict "sslmode" $sslmode }}
{{- range $nativeKey, $sqlKey := dict "ca_file" "sslrootcert" "cert_file" "sslcert" "key_file" "sslkey" }}
{{- with index $target.tls $nativeKey }}
{{- $_ := set $params $sqlKey . }}
{{- end }}
{{- end }}
{{- $sql := mustMergeOverwrite (dict "driver" "postgres" "host" $target.host "port" $target.port "database" $target.connectDatabase "additional_params" $params) $credentials }}
{{- if $target.metrics.enabled }}
{{- $receiver := printf "postgresql/%s_metrics" $id }}
{{- $_ := set $generated.receivers $receiver (mustMergeOverwrite (deepCopy $postgresql.receivers.performance) $native $options.performance) }}
{{- $health := printf "sql_query/%s_health" $id }}
{{- $_ := set $generated.receivers $health (mustMergeOverwrite (deepCopy $postgresql.receivers.health) $sql $options.health) }}
{{- $receivers := list $receiver $health }}
{{- range $database := $databases }}
{{- $tables := printf "sql_query/%s_tables_%s" $id $database }}
{{- $_ := set $generated.receivers $tables (mustMergeOverwrite (deepCopy $postgresql.receivers.tables) $sql $options.tables (dict "database" $database)) }}
{{- $receivers = append $receivers $tables }}
{{- end }}
{{- $base := required "dbMonitoring metrics requires config.service.pipelines.metrics" $config.service.pipelines.metrics }}
{{- $_ := set $generated.service.pipelines (printf "metrics/%s" $id) (dict "receivers" $receivers "processors" (list "memory_limiter" $identity $semconv "batch/db_monitoring") "exporters" $base.exporters) }}
{{- end }}
{{- if or $target.querySamples.enabled $target.topQueries.enabled }}
{{- $receiver := printf "postgresql/%s_queries" $id }}
{{- $receivers := list $receiver }}
{{- $separateSamples := and $target.querySamples.enabled $target.topQueries.enabled (not (deepEqual $options.querySamples $options.topQueries)) }}
{{- $events := dict
    "db.server.query_sample" (dict "enabled" (and $target.querySamples.enabled (not $separateSamples)))
    "db.server.top_query" (dict "enabled" $target.topQueries.enabled) }}
{{- $queries := mustMergeOverwrite (deepCopy $postgresql.receivers.queries) $native ($options.topQueries | default $options.querySamples) (dict "events" $events) }}
{{- if $target.topQueries.enabled }}
{{- $_ := set $queries.top_query_collection "collection_interval" $options.topQueries.collection_interval }}
{{- with $target.topQueries.planCacheTTL }}
{{- $_ := set $queries.top_query_collection "query_plan_cache_ttl" . }}
{{- end }}
{{- end }}
{{- $_ := set $generated.receivers $receiver $queries }}
{{- if $separateSamples }}
{{- $sampleReceiver := printf "postgresql/%s_samples" $id }}
{{- $sampleEvents := dict "db.server.query_sample" (dict "enabled" true) "db.server.top_query" (dict "enabled" false) }}
{{- $_ := set $generated.receivers $sampleReceiver (mustMergeOverwrite (deepCopy $postgresql.receivers.queries) $native $options.querySamples (dict "events" $sampleEvents)) }}
{{- $receivers = append $receivers $sampleReceiver }}
{{- end }}
{{- $users := list $credentials.username "otel" "rdsadmin" "otel_catalog" }}
{{- if hasKey $target "excludeUsers" }}
{{- $users = $target.excludeUsers }}
{{- end }}
{{- $processors := list "memory_limiter" }}
{{- with $users }}
{{- $conditions := list }}
{{- range $user := uniq . }}
{{- $conditions = append $conditions (printf "attributes[\"postgresql.rolname\"] == %s" (toJson $user)) }}
{{- $conditions = append $conditions (printf "attributes[\"user.name\"] == %s" (toJson $user)) }}
{{- end }}
{{- $filter := printf "filter/%s_own_queries" $id }}
{{- $_ := set $generated.processors $filter (dict "error_mode" "ignore" "logs" (dict "log_record" $conditions)) }}
{{- $processors = append $processors $filter }}
{{- end }}
{{- $processors = concat $processors (list $identity $semconv "batch/db_monitoring") }}
{{- $exporters := include "opentelemetry-collector.dbMonitoringLogExporters" (dict "config" $config "generated" $generated.exporters "kind" "queries") | fromYamlArray }}
{{- $_ := set $generated.service.pipelines (printf "logs/%s_queries" $id) (dict "receivers" $receivers "processors" $processors "exporters" $exporters) }}
{{- end }}
{{- if $target.catalog.enabled }}
{{- $details := printf "sql_query/%s_details" $id }}
{{- $_ := set $generated.receivers $details (mustMergeOverwrite (deepCopy $postgresql.receivers.details) $sql $options.details) }}
{{- $receivers := list $details }}
{{- range $database := $databases }}
{{- $schema := printf "sql_query/%s_schema_%s" $id $database }}
{{- $_ := set $generated.receivers $schema (mustMergeOverwrite (deepCopy $postgresql.receivers.schema) $sql $options.schema (dict "database" $database)) }}
{{- $receivers = append $receivers $schema }}
{{- end }}
{{- $catalog := "transform/db_monitoring_catalog" }}
{{- $_ := set $generated.processors $catalog $postgresql.processors.catalog }}
{{- $exporters := include "opentelemetry-collector.dbMonitoringLogExporters" (dict "config" $config "generated" $generated.exporters "kind" "catalog") | fromYamlArray }}
{{- $_ := set $generated.service.pipelines (printf "logs/%s_catalog" $id) (dict "receivers" $receivers "processors" (list "memory_limiter" $identity $catalog "batch/db_monitoring") "exporters" $exporters) }}
{{- end }}
{{- end }}
{{- $iamExtensions := keys $generated.extensions | sortAlpha }}
{{- $result := mustMergeOverwrite $generated $config }}
{{- if $iamExtensions }}
{{- $_ := set $result.service "extensions" (concat ($result.service.extensions | default list) $iamExtensions | uniq) }}
{{- end }}
{{- $result | toYaml }}
{{- end }}

{{- define "opentelemetry-collector.dbMonitoringLogExporters" -}}
{{- $base := required (printf "dbMonitoring %s requires config.service.pipelines.logs" .kind) .config.service.pipelines.logs }}
{{- $exporters := list }}
{{- range $exporter := $base.exporters }}
{{- if eq (first (splitList "/" $exporter)) "coralogix" }}
{{- $name := printf "coralogix/%s_db_monitoring_%s" (last (splitList "/" $exporter)) $.kind }}
{{- $settings := deepCopy (index $.config.exporters $exporter) }}
{{- $_ := set $settings "subsystem_name_attributes" list }}
{{- if eq $.kind "catalog" }}
{{- $settings = mustMergeOverwrite $settings (dict "application_name" "resource" "subsystem_name" "catalog" "logs" (dict "headers" (dict "x-coralogix-ingress" "metadata-as-otlp-logs/v1"))) }}
{{- $_ := set $settings "application_name_attributes" list }}
{{- else }}
{{- $_ := set $settings "subsystem_name" "postgresql-slow-queries" }}
{{- end }}
{{- $_ := set $.generated $name $settings }}
{{- $exporters = append $exporters $name }}
{{- else }}
{{- $exporters = append $exporters $exporter }}
{{- end }}
{{- end }}
{{- toYaml $exporters }}
{{- end }}
