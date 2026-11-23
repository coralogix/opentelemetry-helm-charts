{{/* Database pipelines use target metadata, rather than collector host metadata. */}}
{{- define "opentelemetry-collector.applyDbMonitoringConfig" -}}
{{- $root := .root }}
{{- $config := .config }}
{{- $generated := dict "receivers" dict "processors" dict "exporters" dict "service" (dict "pipelines" dict) }}
{{- $names := dict }}
{{- $postgresql := $root.Files.Get "config/db-monitoring/postgresql.yaml" | fromYaml }}
{{- $defaults := dict
    "port" 5432
    "connectDatabase" "postgres"
    "collectionInterval" "5m"
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
{{- $connection := dict "username" $target.username "password" $target.password "collection_interval" $target.collectionInterval }}
{{- $host := $target.host }}
{{- if contains ":" $host }}
{{- $host = printf "[%s]" $host }}
{{- end }}
{{- $native := mustMergeOverwrite (deepCopy $connection) (dict "endpoint" (printf "%s:%v" $host $target.port) "connect_database" $target.connectDatabase "databases" $databases "tls" $target.tls) }}
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
{{- $sql := mustMergeOverwrite (deepCopy $connection) (dict "driver" "postgres" "host" $target.host "port" $target.port "database" $target.connectDatabase "additional_params" $params) }}
{{- if $target.metrics.enabled }}
{{- $receiver := printf "postgresql/%s_metrics" $id }}
{{- $_ := set $generated.receivers $receiver (mustMergeOverwrite (deepCopy $postgresql.receivers.performance) $native) }}
{{- $health := printf "sql_query/%s_health" $id }}
{{- $_ := set $generated.receivers $health (mustMergeOverwrite (deepCopy $postgresql.receivers.health) $sql) }}
{{- $receivers := list $receiver $health }}
{{- range $database := $databases }}
{{- $tables := printf "sql_query/%s_tables_%s" $id $database }}
{{- $_ := set $generated.receivers $tables (mustMergeOverwrite (deepCopy $postgresql.receivers.tables) $sql (dict "database" $database)) }}
{{- $receivers = append $receivers $tables }}
{{- end }}
{{- $base := required "dbMonitoring metrics requires config.service.pipelines.metrics" $config.service.pipelines.metrics }}
{{- $_ := set $generated.service.pipelines (printf "metrics/%s" $id) (dict "receivers" $receivers "processors" (list "memory_limiter" $identity $semconv "batch/db_monitoring") "exporters" $base.exporters) }}
{{- end }}
{{- if or $target.querySamples.enabled $target.topQueries.enabled }}
{{- $receiver := printf "postgresql/%s_queries" $id }}
{{- $events := dict "db.server.query_sample" (dict "enabled" $target.querySamples.enabled) "db.server.top_query" (dict "enabled" $target.topQueries.enabled) }}
{{- $_ := set $generated.receivers $receiver (mustMergeOverwrite (deepCopy $postgresql.receivers.queries) $native (dict "events" $events)) }}
{{- $filter := printf "filter/%s_own_queries" $id }}
{{- $user := $target.username | toJson }}
{{- $_ := set $generated.processors $filter (dict "error_mode" "ignore" "logs" (dict "log_record" (list (printf "attributes[\"postgresql.rolname\"] == %s" $user) (printf "attributes[\"user.name\"] == %s" $user)))) }}
{{- $base := required "dbMonitoring query events requires config.service.pipelines.logs" $config.service.pipelines.logs }}
{{- $_ := set $generated.service.pipelines (printf "logs/%s_queries" $id) (dict "receivers" (list $receiver) "processors" (list "memory_limiter" $filter $identity $semconv "batch/db_monitoring") "exporters" $base.exporters) }}
{{- end }}
{{- if $target.catalog.enabled }}
{{- $details := printf "sql_query/%s_details" $id }}
{{- $_ := set $generated.receivers $details (mustMergeOverwrite (deepCopy $postgresql.receivers.details) $sql (dict "collection_interval" "10m")) }}
{{- $receivers := list $details }}
{{- range $database := $databases }}
{{- $schema := printf "sql_query/%s_schema_%s" $id $database }}
{{- $_ := set $generated.receivers $schema (mustMergeOverwrite (deepCopy $postgresql.receivers.schema) $sql (dict "database" $database "collection_interval" "10m")) }}
{{- $receivers = append $receivers $schema }}
{{- end }}
{{- $catalog := "transform/db_monitoring_catalog" }}
{{- $_ := set $generated.processors $catalog $postgresql.processors.catalog }}
{{- $base := required "dbMonitoring catalog requires config.service.pipelines.logs" $config.service.pipelines.logs }}
{{- $exporters := list }}
{{- range $exporter := $base.exporters }}
{{- if eq (first (splitList "/" $exporter)) "coralogix" }}
{{- $name := printf "coralogix/%s_db_monitoring_catalog" (last (splitList "/" $exporter)) }}
{{- $settings := mustMergeOverwrite (deepCopy (index $config.exporters $exporter)) (dict "application_name" "resource" "subsystem_name" "catalog" "logs" (dict "headers" (dict "x-coralogix-ingress" "metadata-as-otlp-logs/v1"))) }}
{{- $_ := set $settings "application_name_attributes" list }}
{{- $_ := set $settings "subsystem_name_attributes" list }}
{{- $_ := set $generated.exporters $name $settings }}
{{- $exporters = append $exporters $name }}
{{- else }}
{{- $exporters = append $exporters $exporter }}
{{- end }}
{{- end }}
{{- $_ := set $generated.service.pipelines (printf "logs/%s_catalog" $id) (dict "receivers" $receivers "processors" (list "memory_limiter" $identity $catalog "batch/db_monitoring") "exporters" $exporters) }}
{{- end }}
{{- end }}
{{- mustMergeOverwrite $generated $config | toYaml }}
{{- end }}
