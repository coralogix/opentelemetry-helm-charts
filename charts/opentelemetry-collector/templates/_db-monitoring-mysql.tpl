{{- define "opentelemetry-collector.addDbMonitoringMysql" -}}
{{- $generated := .generated }}
{{- $config := .config }}
{{- $mysql := .root.Files.Get "config/db-monitoring/mysql.yaml" | fromYaml }}
{{- $names := dict }}
{{- range $target := .root.Values.presets.dbMonitoring.mysql }}
{{- if hasKey $names $target.name }}
{{- fail (printf "dbMonitoring.mysql: duplicate target name %q" $target.name) }}
{{- end }}
{{- $_ := set $names $target.name true }}
{{- $id := printf "db_monitoring_mysql_%s" $target.name }}
{{- $metrics := dig "metrics" "enabled" true $target }}
{{- $top := dig "topQueries" "enabled" false $target }}
{{- $samples := dig "querySamples" "enabled" false $target }}
{{- $catalogEnabled := dig "catalog" "enabled" false $target }}
{{- $serverLogs := $target.serverLogs | default dict }}
{{- if not (or $metrics $top $samples $catalogEnabled $serverLogs.errorPaths $serverLogs.slowPaths) }}
{{- continue }}
{{- end }}
{{- $tls := mustMergeOverwrite (dict "insecure" false "insecure_skip_verify" false) ($target.tls | default dict) }}
{{- $port := $target.port | default 3306 }}
{{- $host := $target.host }}
{{- if contains ":" $host }}
{{- $host = printf "[%s]" $host }}
{{- end }}
{{- $native := dict "endpoint" (printf "%s:%v" $host $port) "username" $target.username "tls" $tls }}
{{- $sqlAuth := $target.sqlAuth }}
{{- if hasKey $target.auth "password" }}
{{- $_ := set $native "password" $target.auth.password }}
{{- $sqlAuth = $sqlAuth | default (dict "username" $target.username "password" $target.auth.password) }}
{{- else if or $metrics $top $samples }}
{{- if $tls.insecure }}
{{- fail (printf "dbMonitoring.mysql %q: AWS IAM authentication requires TLS" $target.name) }}
{{- end }}
{{- $region := $target.auth.aws_iam.region }}
{{- $extension := printf "aws_iam_db_auth/%s" $region }}
{{- $_ := set $generated.extensions $extension (dict "region" $region) }}
{{- $_ := set $native "db_auth" $extension }}
{{- end }}
{{- if and (or $metrics $catalogEnabled) (not $sqlAuth) }}
{{- fail (printf "dbMonitoring.mysql %q: sqlAuth is required for metrics or catalog collection with AWS IAM authentication" $target.name) }}
{{- end }}
{{- $sqlTLS := ternary "false" (ternary "skip-verify" "true" $tls.insecure_skip_verify) $tls.insecure }}
{{- $sql := dict "host" $host "port" $port "database" "information_schema" "driver" "mysql"
    "additional_params" (dict "tls" $sqlTLS "group_concat_max_len" 67108864 "information_schema_stats_expiry" 0) }}
{{- if $sqlAuth }}
{{- $sql = mustMergeOverwrite $sql $sqlAuth }}
{{- end }}
{{- $identity := printf "resource/%s" $id }}
{{- $attributes := mustMergeOverwrite (deepCopy ($target.resourceAttributes | default dict)) (dict
    "db.system.name" "mysql" "cx.db.instance.id" $target.instanceId "server.address" $target.host "server.port" $port) }}
{{- $resource := list }}
{{- range $key, $value := $attributes }}
{{- $resource = append $resource (dict "key" $key "value" $value "action" "upsert") }}
{{- end }}
{{- $_ := set $generated.processors $identity (dict "attributes" $resource) }}
{{- $semconv := "transform/db_monitoring_mysql" }}
{{- $_ := set $generated.processors $semconv $mysql.processors.semconv }}
{{- $_ := set $generated.processors "batch/db_monitoring" dict }}
{{- $options := dict }}
{{- $defaults := dict "performance" $mysql.receivers.performance.collection_interval
    "health" $mysql.receivers.health.collection_interval "tables" $mysql.receivers.tables.collection_interval
    "topQueries" $mysql.receivers.queries.top_query_collection.collection_interval
    "querySamples" $mysql.receivers.queries.collection_interval
    "details" $mysql.receivers.details.collection_interval "schema" $mysql.receivers.schema.collection_interval }}
{{- range $kind, $interval := $defaults }}
{{- if and $target.collectionInterval (has $kind (list "performance" "health" "tables" "querySamples")) }}
{{- $interval = $target.collectionInterval }}
{{- end }}
{{- $settings := get ($target.receivers | default dict) $kind | default dict }}
{{- $timing := dict "collection_interval" ($settings.collectionInterval | default $interval) }}
{{- with $settings.initialDelay }}
{{- $_ := set $timing "initial_delay" . }}
{{- end }}
{{- with $settings.timeout }}
{{- $_ := set $timing "timeout" . }}
{{- end }}
{{- $_ := set $options $kind $timing }}
{{- end }}
{{- if $metrics }}
{{- $performance := printf "mysql/%s_metrics" $id }}
{{- $_ := set $generated.receivers $performance (mustMergeOverwrite (deepCopy $mysql.receivers.performance) $native $options.performance) }}
{{- $receivers := list $performance }}
{{- range $kind := list "health" "tables" }}
{{- $receiver := printf "sql_query/%s_%s" $id $kind }}
{{- $_ := set $generated.receivers $receiver (mustMergeOverwrite (deepCopy (get $mysql.receivers $kind)) $sql (get $options $kind)) }}
{{- $receivers = append $receivers $receiver }}
{{- end }}
{{- $exporters := include "opentelemetry-collector.dbMonitoringExporters" (dict "config" $config "generated" $generated.exporters "engine" "mysql" "kind" "metrics") | fromYamlArray }}
{{- $_ := set $generated.service.pipelines (printf "metrics/%s" $id) (dict "receivers" $receivers "processors" (list "memory_limiter" $identity $semconv "batch/db_monitoring") "exporters" $exporters) }}
{{- end }}
{{- if or $top $samples $serverLogs.errorPaths $serverLogs.slowPaths }}
{{- $users := list $target.username "otel" "otel_catalog" "rdsadmin" }}
{{- if $sqlAuth }}
{{- $users = append $users $sqlAuth.username }}
{{- end }}
{{- if hasKey $target "excludeUsers" }}
{{- $users = $target.excludeUsers }}
{{- end }}
{{- $filterConfig := deepCopy $mysql.processors.filterQueries }}
{{- range $user := uniq $users }}
{{- $_ := set $filterConfig.logs "log_record" (append $filterConfig.logs.log_record (printf "attributes[\"user.name\"] == %s" (toJson $user))) }}
{{- end }}
{{- $filter := printf "filter/%s_own_queries" $id }}
{{- $_ := set $generated.processors $filter $filterConfig }}
{{- $processors := list "memory_limiter" $filter $identity $semconv }}
{{- if or $top $samples }}
{{- $separate := and $top $samples (not (deepEqual $options.topQueries $options.querySamples)) }}
{{- $events := dict "db.server.top_query" (dict "enabled" $top)
    "db.server.query_sample" (dict "enabled" (and $samples (not $separate)))
    "db.server.query_plan" (dict "enabled" (and $top (dig "topQueries" "planEvents" false $target))) }}
{{- $receiver := printf "mysql/%s_queries" $id }}
{{- $timing := ternary $options.topQueries $options.querySamples $top }}
{{- $queries := mustMergeOverwrite (deepCopy $mysql.receivers.queries) $native $timing (dict "events" $events) }}
{{- if $top }}
{{- $_ := set $queries.top_query_collection "collection_interval" $timing.collection_interval }}
{{- with dig "topQueries" "planCacheTTL" "" $target }}
{{- $_ := set $queries.top_query_collection "query_plan_cache_ttl" . }}
{{- end }}
{{- end }}
{{- $_ := set $generated.receivers $receiver $queries }}
{{- $receivers := list $receiver }}
{{- if $separate }}
{{- $sampleReceiver := printf "mysql/%s_samples" $id }}
{{- $sampleEvents := dict "db.server.query_sample" (dict "enabled" true)
    "db.server.top_query" (dict "enabled" false) "db.server.query_plan" (dict "enabled" false) }}
{{- $_ := set $generated.receivers $sampleReceiver (mustMergeOverwrite (deepCopy $mysql.receivers.queries) $native $options.querySamples (dict "events" $sampleEvents)) }}
{{- $receivers = append $receivers $sampleReceiver }}
{{- end }}
{{- $exporters := include "opentelemetry-collector.dbMonitoringExporters" (dict "config" $config "generated" $generated.exporters "engine" "mysql" "kind" "queries") | fromYamlArray }}
{{- $_ := set $generated.service.pipelines (printf "logs/%s_queries" $id) (dict "receivers" $receivers "processors" (append $processors "batch/db_monitoring") "exporters" $exporters) }}
{{- end }}
{{- if or $serverLogs.errorPaths $serverLogs.slowPaths }}
{{- $_ := include "opentelemetry-collector.addDbMonitoringMysqlServerLogs" (dict
    "config" $config "generated" $generated "mysql" $mysql "settings" $serverLogs "id" $id "processors" $processors) }}
{{- end }}
{{- end }}
{{- if $catalogEnabled }}
{{- $receivers := list }}
{{- $statements := list }}
{{- range $kind, $event := dict "details" "db.instance" "schema" "db.schema" }}
{{- $receiver := printf "sql_query/%s_%s" $id $kind }}
{{- $timing := get $options $kind }}
{{- $_ := set $generated.receivers $receiver (mustMergeOverwrite (deepCopy (get $mysql.receivers $kind)) $sql $timing) }}
{{- $receivers = append $receivers $receiver }}
{{- $interval := dig $receiver "collection_interval" $timing.collection_interval ($config.receivers | default dict) }}
{{- $statements = append $statements (printf "set(attributes[\"otel.entity.interval\"], Milliseconds(Duration(%s))) where body == %s" (toJson $interval) (toJson $event)) }}
{{- end }}
{{- $catalogProcessor := "transform/db_monitoring_mysql_catalog" }}
{{- $_ := set $generated.processors $catalogProcessor $mysql.processors.catalog }}
{{- $intervalProcessor := printf "transform/%s_catalog_interval" $id }}
{{- $_ := set $generated.processors $intervalProcessor (dict "log_statements" (list (dict "context" "log" "statements" $statements))) }}
{{- $processors := list "memory_limiter" $identity $catalogProcessor $intervalProcessor "batch/db_monitoring" }}
{{- $exporters := include "opentelemetry-collector.dbMonitoringExporters" (dict "config" $config "generated" $generated.exporters "kind" "catalog") | fromYamlArray }}
{{- $_ := set $generated.service.pipelines (printf "logs/%s_catalog" $id) (dict "receivers" $receivers "processors" $processors "exporters" $exporters) }}
{{- end }}
{{- end }}
{{- end }}

{{- define "opentelemetry-collector.addDbMonitoringMysqlServerLogs" -}}
{{- $exporters := include "opentelemetry-collector.dbMonitoringExporters" (dict "config" .config "generated" .generated.exporters "engine" "mysql" "kind" "server_logs") | fromYamlArray }}
{{- range $kind, $paths := dict "error" .settings.errorPaths "slow" .settings.slowPaths }}
{{- if $paths }}
{{- $receiver := printf "file_log/%s_%s" $.id $kind }}
{{- $settings := dict "include" $paths "start_at" ($.settings.startAt | default "beginning") "poll_interval" ($.settings.pollInterval | default "200ms") }}
{{- $_ := set $.generated.receivers $receiver (mustMergeOverwrite (deepCopy (get $.mysql.serverLogs $kind)) $settings) }}
{{- $parse := printf "transform/db_monitoring_mysql_%s_logs" $kind }}
{{- $_ := set $.generated.processors $parse (get $.mysql.processors (printf "%sLogs" $kind)) }}
{{- $processors := concat (list "memory_limiter" $parse) (rest $.processors) }}
{{- if eq $kind "slow" }}
{{- $redact := "redaction/db_monitoring_mysql_sql" }}
{{- $clean := "transform/db_monitoring_mysql_clean_sql" }}
{{- $_ := set $.generated.processors $redact $.mysql.processors.redactSQL }}
{{- $_ := set $.generated.processors $clean $.mysql.processors.cleanSQL }}
{{- $processors = concat $processors (list $redact $clean) }}
{{- end }}
{{- $_ := set $.generated.service.pipelines (printf "logs/%s_%s" $.id $kind) (dict "receivers" (list $receiver) "processors" (append $processors "batch/db_monitoring") "exporters" $exporters) }}
{{- end }}
{{- end }}
{{- end }}
