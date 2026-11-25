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
    "receivers" dict
    "tls" (dict "insecure" false "insecure_skip_verify" false)
    "metrics" (dict "enabled" true)
    "querySamples" (dict "enabled" false)
    "activitySnapshots" (dict "enabled" false)
    "topQueries" (dict "enabled" false)
    "catalog" (dict "enabled" false)
    "rdsLogs" (dict "enabled" false)
}}
{{- range $target := $root.Values.presets.dbMonitoring.postgresql }}
{{- if hasKey $names $target.name }}
{{- fail (printf "dbMonitoring.postgresql: duplicate target name %q" $target.name) }}
{{- end }}
{{- $_ := set $names $target.name true }}
{{- $target = mustMergeOverwrite (deepCopy $defaults) (deepCopy $target) }}
{{- $queryLogs := or $target.querySamples.enabled $target.activitySnapshots.enabled $target.topQueries.enabled $target.rdsLogs.enabled }}
{{- if not (or $target.metrics.enabled $queryLogs $target.catalog.enabled) }}
{{- continue }}
{{- end }}
{{- $resourceAttributes := $target.resourceAttributes | default dict }}
{{- $rds := or $target.rdsLogs.enabled (hasKey $target.auth "aws_iam") (eq (toString (get $resourceAttributes "cloud.platform")) "aws_rds") (regexMatch "\\.rds\\.amazonaws\\.com(\\.cn)?\\.?$" $target.host) }}
{{- $intervals := dict }}
{{- $interval := $target.collectionInterval | default "60s" }}
{{- if $target.metrics.enabled }}
{{- $intervals = dict "performance" $interval "health" $interval "tables" ($target.collectionInterval | default "5m") }}
{{- end }}
{{- if $target.querySamples.enabled }}
{{- $_ := set $intervals "querySamples" $interval }}
{{- end }}
{{- if $target.activitySnapshots.enabled }}
{{- $_ := set $intervals "activitySnapshots" $postgresql.receivers.activity.collection_interval }}
{{- end }}
{{- if $target.topQueries.enabled }}
{{- $_ := set $intervals "topQueries" $postgresql.receivers.queries.top_query_collection.collection_interval }}
{{- end }}
{{- if $target.catalog.enabled }}
{{- $_ := set $intervals "details" "5m" }}
{{- $_ := set $intervals "schema" "5m" }}
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
{{- else if $intervals }}
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
{{- $attributes := mustMergeOverwrite (deepCopy $resourceAttributes) (dict "db.system.name" "postgresql" "server.address" $target.host "server.port" $target.port "cx.db.instance.id" $target.instanceId) }}
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
{{- $excludedDatabases := list }}
{{- if hasKey $target "excludeDatabases" }}
{{- $excludedDatabases = $target.excludeDatabases }}
{{- else if $rds }}
{{- $excludedDatabases = list "rdsadmin" }}
{{- end }}
{{- if $excludedDatabases }}
{{- $_ := set $native "exclude_databases" $excludedDatabases }}
{{- end }}
{{- range $excludedDatabases }}
{{- $databases = without $databases . }}
{{- end }}
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
{{- if $queryLogs }}
{{- $users := list $credentials.username "otel" "rdsadmin" "otel_catalog" }}
{{- if hasKey $target "excludeUsers" }}
{{- $users = $target.excludeUsers }}
{{- end }}
{{- $queryProcessors := list }}
{{- with $users }}
{{- $conditions := list }}
{{- range $user := uniq . }}
{{- $conditions = append $conditions (printf "attributes[\"postgresql.rolname\"] == %s" (toJson $user)) }}
{{- $conditions = append $conditions (printf "attributes[\"user.name\"] == %s" (toJson $user)) }}
{{- end }}
{{- $filter := printf "filter/%s_own_queries" $id }}
{{- $_ := set $generated.processors $filter (dict "error_mode" "ignore" "logs" (dict "log_record" $conditions)) }}
{{- $queryProcessors = append $queryProcessors $filter }}
{{- end }}
{{- $queryProcessors = append $queryProcessors $identity }}
{{- $exporters := include "opentelemetry-collector.dbMonitoringLogExporters" (dict "config" $config "generated" $generated.exporters "kind" "queries") | fromYamlArray }}
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
{{- $processors := concat (list "memory_limiter") $queryProcessors (list $semconv "batch/db_monitoring") }}
{{- $_ := set $generated.service.pipelines (printf "logs/%s_queries" $id) (dict "receivers" $receivers "processors" $processors "exporters" $exporters) }}
{{- end }}
{{- if $target.activitySnapshots.enabled }}
{{- $receiver := printf "sql_query/%s_activity" $id }}
{{- $_ := set $generated.receivers $receiver (mustMergeOverwrite (deepCopy $postgresql.receivers.activity) $sql $options.activitySnapshots) }}
{{- $prepare := "transform/db_monitoring_activity" }}
{{- $redact := "redaction/db_monitoring_activity" }}
{{- $clean := "transform/db_monitoring_activity_clean" }}
{{- $_ := set $generated.processors $prepare $postgresql.processors.activity }}
{{- $_ := set $generated.processors $redact $postgresql.processors.redactActivity }}
{{- $_ := set $generated.processors $clean $postgresql.processors.cleanActivity }}
{{- $processors := concat (list "memory_limiter") $queryProcessors (list $prepare $redact $clean $semconv "batch/db_monitoring") }}
{{- $_ := set $generated.service.pipelines (printf "logs/%s_activity" $id) (dict "receivers" (list $receiver) "processors" $processors "exporters" $exporters) }}
{{- end }}
{{- if $target.rdsLogs.enabled }}
{{- $receiver := printf "aws_cloudwatch/%s_rds_logs" $id }}
{{- $region := required (printf "dbMonitoring.postgresql %q: rdsLogs.region is required without auth.aws_iam.region" $target.name) (coalesce $target.rdsLogs.region (dig "aws_iam" "region" "" $target.auth)) }}
{{- $logGroup := $target.rdsLogs.logGroup | default (printf "/aws/rds/instance/%s/postgresql" $target.name) }}
{{- $group := dict }}
{{- with $target.rdsLogs.logStreams }}
{{- $_ := set $group "names" . }}
{{- end }}
{{- $logs := dict
    "poll_interval" ($target.rdsLogs.pollInterval | default "30s")
    "initial_lookback" ($target.rdsLogs.initialLookback | default "1m")
    "groups" (dict "named" (dict $logGroup $group)) }}
{{- $_ := set $generated.receivers $receiver (dict "region" $region "logs" $logs) }}
{{- $transform := "transform/db_monitoring_rds_plans" }}
{{- $filter := "filter/db_monitoring_rds_plans" }}
{{- $_ := set $generated.processors $transform $postgresql.processors.rdsPlans }}
{{- $_ := set $generated.processors $filter (dict "error_mode" "ignore" "logs" (dict "log_record" (list "attributes[\"postgresql.query_plan\"] == nil"))) }}
{{- $processors := concat (list "memory_limiter" $transform $filter) $queryProcessors (list $semconv "batch/db_monitoring") }}
{{- $_ := set $generated.service.pipelines (printf "logs/%s_rds_plans" $id) (dict "receivers" (list $receiver) "processors" $processors "exporters" $exporters) }}
{{- end }}
{{- end }}
{{- if $target.catalog.enabled }}
{{- $details := printf "sql_query/%s_details" $id }}
{{- $_ := set $generated.receivers $details (mustMergeOverwrite (deepCopy $postgresql.receivers.details) $sql $options.details) }}
{{- $receivers := list $details }}
{{- $receiverOverrides := $config.receivers | default dict }}
{{- $detailsInterval := dig $details "collection_interval" $options.details.collection_interval $receiverOverrides }}
{{- $setInterval := "set(attributes[\"otel.entity.interval\"], Milliseconds(Duration(%s))) where %s" }}
{{- $intervalStatements := list (printf $setInterval (toJson $detailsInterval) `body == "db.instance"`) }}
{{- $schemaDefaults := deepCopy $postgresql.receivers.schema }}
{{- if $rds }}
{{- $_ := set $schemaDefaults "initial_delay" "30s" }}
{{- end }}
{{- range $database := $databases }}
{{- $schema := printf "sql_query/%s_schema_%s" $id $database }}
{{- $_ := set $generated.receivers $schema (mustMergeOverwrite (deepCopy $schemaDefaults) $sql $options.schema (dict "database" $database)) }}
{{- $receivers = append $receivers $schema }}
{{- $schemaInterval := dig $schema "collection_interval" $options.schema.collection_interval $receiverOverrides }}
{{- $intervalStatements = append $intervalStatements (printf $setInterval (toJson $schemaInterval) (printf `body == "db.schema" and attributes["db.namespace"] == %s` (toJson $database))) }}
{{- end }}
{{- $catalog := "transform/db_monitoring_catalog" }}
{{- $_ := set $generated.processors $catalog $postgresql.processors.catalog }}
{{- $catalogInterval := printf "transform/%s_catalog_interval" $id }}
{{- $_ := set $generated.processors $catalogInterval (dict "log_statements" (list (dict "context" "log" "statements" $intervalStatements))) }}
{{- $exporters := include "opentelemetry-collector.dbMonitoringLogExporters" (dict "config" $config "generated" $generated.exporters "kind" "catalog") | fromYamlArray }}
{{- $_ := set $generated.service.pipelines (printf "logs/%s_catalog" $id) (dict "receivers" $receivers "processors" (list "memory_limiter" $identity $catalog $catalogInterval "batch/db_monitoring") "exporters" $exporters) }}
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
