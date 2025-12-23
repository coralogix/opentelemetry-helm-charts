{{/*
Service Discovery Configuration
Automatically discovers and monitors common databases and services

Supported distributions:
- standalone: Uses host_observer to scan local processes
- macos: Uses host_observer to scan local processes
*/}}

{{- define "opentelemetry-collector.applyDiscoveryConfig" -}}
{{- $config := .config }}
{{- $isStandalone := or (eq .Values.Values.distribution "standalone") (eq .Values.Values.distribution "macos") }}

{{- if $isStandalone }}
  {{- $discoveryConfig := include "opentelemetry-collector.discoveryStandaloneConfig" .Values | fromYaml }}
  {{- $config = mustMergeOverwrite $discoveryConfig $config }}

  {{- /* Add host_observer extension */ -}}
  {{- $_ := set $config.service "extensions" (append ($config.service.extensions | default list) "host_observer" | uniq) }}

  {{- /* Add discovery metrics pipeline */ -}}
  {{- $_ := set $config.service.pipelines "metrics/discovery" (dict
      "receivers" (list "receiver_creator/discovery")
      "processors" (list "memory_limiter" "batch" "resourcedetection")
      "exporters" (list "coralogix")
  ) }}
{{- end }}

{{- $config | toYaml }}
{{- end }}

{{/*
Standalone Discovery Config
Uses host_observer to discover services running on local host
Matches services by process command name and/or port number
*/}}
{{- define "opentelemetry-collector.discoveryStandaloneConfig" -}}
extensions:
  host_observer:
    refresh_interval: {{ .Values.presets.discovery.observer.refresh_interval | default "10s" }}

receivers:
  receiver_creator/discovery:
    watch_observers:
      - host_observer
    receivers:
{{- if .Values.presets.discovery.services.postgresql.enabled }}
      # PostgreSQL Discovery
      postgresql:
        rule: |
          type == "hostport" and
          ((command != "" and command matches "(?i)postgres") or port == {{ .Values.presets.discovery.services.postgresql.port | default 5432 }}) and
          not (command matches "coralogix|otel")
        config:
          endpoint: "`endpoint`"
          username: ${env:POSTGRES_USER:-{{ .Values.presets.discovery.services.postgresql.default_user | default "postgres" }}}
          password: ${env:POSTGRES_PASSWORD}
          databases:
            - ${env:POSTGRES_DB:-{{ .Values.presets.discovery.services.postgresql.default_db | default "postgres" }}}
          collection_interval: 60s
{{- end }}

{{- if .Values.presets.discovery.services.mysql.enabled }}
      # MySQL Discovery
      mysql:
        rule: |
          type == "hostport" and port != 33060 and
          ((command != "" and command matches "(?i)mysqld") or port == {{ .Values.presets.discovery.services.mysql.port | default 3306 }}) and
          not (command matches "coralogix|otel")
        config:
          endpoint: "`endpoint`"
          username: ${env:MYSQL_USER:-{{ .Values.presets.discovery.services.mysql.default_user | default "root" }}}
          password: ${env:MYSQL_PASSWORD}
          collection_interval: 60s
{{- end }}

{{- if .Values.presets.discovery.services.redis.enabled }}
      # Redis Discovery
      redis:
        rule: |
          type == "hostport" and
          ((command != "" and command matches "(?i)redis-server") or port == {{ .Values.presets.discovery.services.redis.port | default 6379 }}) and
          not (command matches "coralogix|otel")
        config:
          endpoint: "`endpoint`"
          password: ${env:REDIS_PASSWORD}
          collection_interval: 60s
{{- end }}

{{- if .Values.presets.discovery.services.mongodb.enabled }}
      # MongoDB Discovery
      mongodb:
        rule: |
          type == "hostport" and
          ((command != "" and command matches "(?i)mongod") or port == {{ .Values.presets.discovery.services.mongodb.port | default 27017 }}) and
          not (command matches "coralogix|otel")
        config:
          hosts:
            - endpoint: "`endpoint`"
          username: ${env:MONGODB_USER:-{{ .Values.presets.discovery.services.mongodb.default_user | default "admin" }}}
          password: ${env:MONGODB_PASSWORD}
          direct_connection: true
          tls:
            insecure_skip_verify: true
            insecure: false
          timeout: 5s
          collection_interval: 60s
{{- end }}

{{- if .Values.presets.discovery.services.nginx.enabled }}
      # NGINX Discovery
      nginx:
        rule: |
          type == "hostport" and
          ((command != "" and command matches "(?i)nginx") or port == 80 or port == 443) and
          not (command matches "coralogix|otel")
        config:
          endpoint: "http://`endpoint`{{ .Values.presets.discovery.services.nginx.status_endpoint | default "/nginx_status" }}"
          collection_interval: 60s
{{- end }}

{{- if .Values.presets.discovery.services.apache.enabled }}
      # Apache Discovery
      apache:
        rule: |
          type == "hostport" and
          ((command != "" and command matches "(?i)(httpd|apache2)") or port == 80 or port == 443) and
          not (command matches "coralogix|otel|nginx")
        config:
          endpoint: "http://`endpoint`{{ .Values.presets.discovery.services.apache.status_endpoint | default "/server-status?auto" }}"
          collection_interval: 60s
{{- end }}

{{- if .Values.presets.discovery.services.rabbitmq.enabled }}
      # RabbitMQ Discovery
      rabbitmq:
        rule: |
          type == "hostport" and
          ((command != "" and command matches "(?i)rabbitmq") or port == {{ .Values.presets.discovery.services.rabbitmq.management_port | default 15672 }}) and
          not (command matches "coralogix|otel")
        config:
          endpoint: "`endpoint`"
          username: ${env:RABBITMQ_USER:-{{ .Values.presets.discovery.services.rabbitmq.default_user | default "guest" }}}
          password: ${env:RABBITMQ_PASSWORD:-guest}
          collection_interval: 60s
{{- end }}

{{- if .Values.presets.discovery.services.memcached.enabled }}
      # Memcached Discovery
      memcached:
        rule: |
          type == "hostport" and
          ((command != "" and command matches "(?i)memcached") or port == {{ .Values.presets.discovery.services.memcached.port | default 11211 }}) and
          not (command matches "coralogix|otel")
        config:
          endpoint: "`endpoint`"
          collection_interval: 60s
{{- end }}

{{- if .Values.presets.discovery.services.elasticsearch.enabled }}
      # Elasticsearch Discovery
      elasticsearch:
        rule: |
          type == "hostport" and
          ((command != "" and command matches "(?i)elasticsearch") or port == {{ .Values.presets.discovery.services.elasticsearch.port | default 9200 }}) and
          not (command matches "coralogix|otel")
        config:
          endpoint: "http://`endpoint`"
          username: ${env:ELASTICSEARCH_USER}
          password: ${env:ELASTICSEARCH_PASSWORD}
          collection_interval: 60s
{{- end }}

{{- if .Values.presets.discovery.services.kafka.enabled }}
      # Kafka Discovery
      kafkametrics:
        rule: |
          type == "hostport" and
          ((command != "" and command matches "(?i)kafka") or port == {{ .Values.presets.discovery.services.kafka.port | default 9092 }}) and
          not (command matches "coralogix|otel")
        config:
          brokers:
            - "`endpoint`"
          collection_interval: 60s
{{- end }}

{{- if .Values.presets.discovery.services.cassandra.enabled }}
      # Cassandra Discovery (JMX)
      jmx/cassandra:
        rule: |
          type == "hostport" and
          ((command != "" and command matches "(?i)cassandra") or port == {{ .Values.presets.discovery.services.cassandra.jmx_port | default 7199 }}) and
          not (command matches "coralogix|otel")
        config:
          jar_path: /opt/opentelemetry-java-contrib-jmx-metrics.jar
          endpoint: "service:jmx:rmi:///jndi/rmi://`endpoint`/jmxrmi"
          target_system: cassandra
          collection_interval: 60s
{{- end }}
{{- end }}
