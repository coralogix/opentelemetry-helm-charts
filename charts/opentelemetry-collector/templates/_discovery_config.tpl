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
  {{- $_ := set $config.service "extensions" (append ($config.service.extensions | default list) "host_observer" | uniq) }}
  {{- $_ := set $config.service.pipelines.metrics "receivers" (append ($config.service.pipelines.metrics.receivers | default list) "receiver_creator/discovery" | uniq) }}
{{- end }}

{{- $config | toYaml }}
{{- end }}

{{/*
Standalone Discovery Config
Uses host_observer to discover services running on local host
Matches services by process command name
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
          command matches "(?i)postgres" and
          not (command matches "coralogix|otel")
        config:
          endpoint: "`endpoint`"
          username: ${env:POSTGRES_USER:-{{ .Values.presets.discovery.services.postgresql.default_user }}}
          password: ${env:POSTGRES_PASSWORD:-{{ .Values.presets.discovery.services.postgresql.default_password }}}
          databases:
            - ${env:POSTGRES_DB:-{{ .Values.presets.discovery.services.postgresql.default_database }}}
          {{- if .Values.presets.discovery.collectionInterval }}
          collection_interval: "{{ .Values.presets.discovery.collectionInterval }}"
          {{- else }}
          collection_interval: 60s
          {{- end }}
{{- end }}

{{- if .Values.presets.discovery.services.mysql.enabled }}
      # MySQL Discovery
      mysql:
        rule: |
          type == "hostport" and
          port != 33060 and
          command matches "(?i)mysqld" and
          not (command matches "coralogix|otel")
        config:
          endpoint: "`endpoint`"
          username: ${env:MYSQL_USER:-{{ .Values.presets.discovery.services.mysql.default_user }}}
          password: ${env:MYSQL_PASSWORD:-{{ .Values.presets.discovery.services.mysql.default_password }}}
          {{- if .Values.presets.discovery.collectionInterval }}
          collection_interval: "{{ .Values.presets.discovery.collectionInterval }}"
          {{- else }}
          collection_interval: 60s
          {{- end }}
{{- end }}

{{- if .Values.presets.discovery.services.redis.enabled }}
      # Redis Discovery
      redis:
        rule: |
          type == "hostport" and
          command matches "(?i)redis" and
          not (command matches "coralogix|otel")
        config:
          endpoint: "`endpoint`"
          password: ${env:REDIS_PASSWORD:-{{ .Values.presets.discovery.services.redis.default_password }}}
          {{- if .Values.presets.discovery.collectionInterval }}
          collection_interval: "{{ .Values.presets.discovery.collectionInterval }}"
          {{- else }}
          collection_interval: 60s
          {{- end }}
{{- end }}

{{- if .Values.presets.discovery.services.mongodb.enabled }}
      # MongoDB Discovery
      mongodb:
        rule: |
          type == "hostport" and
          command matches "(?i)mongo" and
          not (command matches "coralogix|otel")
        config:
          hosts:
            - endpoint: "`endpoint`"
          username: ${env:MONGODB_USER:-{{ .Values.presets.discovery.services.mongodb.default_user }}}
          password: ${env:MONGODB_PASSWORD:-{{ .Values.presets.discovery.services.mongodb.default_password }}}
          direct_connection: true
          tls:
            insecure_skip_verify: {{ .Values.presets.discovery.services.mongodb.tls_insecure_skip_verify | default true }}
            insecure: {{ .Values.presets.discovery.services.mongodb.tls_insecure | default false }}
          {{- if .Values.presets.discovery.collectionInterval }}
          collection_interval: "{{ .Values.presets.discovery.collectionInterval }}"
          {{- else }}
          collection_interval: 60s
          {{- end }}
{{- end }}

{{- if .Values.presets.discovery.services.nginx.enabled }}
      # NGINX Discovery
      nginx:
        rule: |
          type == "hostport" and
          command matches "(?i)nginx" and
          not (command matches "coralogix|otel")
        config:
          endpoint: '`(port in [443] ? "https://" : "http://")``endpoint`{{ .Values.presets.discovery.services.nginx.status_endpoint | default "/nginx_status" }}'
          {{- if .Values.presets.discovery.collectionInterval }}
          collection_interval: "{{ .Values.presets.discovery.collectionInterval }}"
          {{- else }}
          collection_interval: 60s
          {{- end }}
{{- end }}

{{- if .Values.presets.discovery.services.apache.enabled }}
      # Apache Discovery
      apache:
        rule: |
          type == "hostport" and
          command matches "(?i)(httpd|apache2).*" and
          not (command matches "coralogix|otel")
        config:
          endpoint: "http://`endpoint`{{ .Values.presets.discovery.services.apache.status_endpoint | default "/server-status?auto" }}"
          {{- if .Values.presets.discovery.collectionInterval }}
          collection_interval: "{{ .Values.presets.discovery.collectionInterval }}"
          {{- else }}
          collection_interval: 60s
          {{- end }}
{{- end }}

{{- if .Values.presets.discovery.services.rabbitmq.enabled }}
      # RabbitMQ Discovery
      rabbitmq:
        rule: |
          type == "hostport" and
          command matches "(?i)rabbitmq.*" and
          not (command matches "coralogix|otel")
        config:
          endpoint: "`endpoint`"
          username: ${env:RABBITMQ_USER:-{{ .Values.presets.discovery.services.rabbitmq.default_user }}}
          password: ${env:RABBITMQ_PASSWORD:-{{ .Values.presets.discovery.services.rabbitmq.default_password }}}
          {{- if .Values.presets.discovery.collectionInterval }}
          collection_interval: "{{ .Values.presets.discovery.collectionInterval }}"
          {{- else }}
          collection_interval: 60s
          {{- end }}
{{- end }}

{{- if .Values.presets.discovery.services.memcached.enabled }}
      # Memcached Discovery
      memcached:
        rule: |
          type == "hostport" and
          command matches "(?i)memcached" and
          not (command matches "coralogix|otel")
        config:
          endpoint: "`endpoint`"
          {{- if .Values.presets.discovery.collectionInterval }}
          collection_interval: "{{ .Values.presets.discovery.collectionInterval }}"
          {{- else }}
          collection_interval: 60s
          {{- end }}
{{- end }}

{{- if .Values.presets.discovery.services.elasticsearch.enabled }}
      # Elasticsearch Discovery
      elasticsearch:
        rule: |
          type == "hostport" and
          command matches "(?i)elasticsearch" and
          not (command matches "coralogix|otel")
        config:
          endpoint: "http://`endpoint`"
          username: ${env:ELASTICSEARCH_USER:-{{ .Values.presets.discovery.services.elasticsearch.default_user }}}
          password: ${env:ELASTICSEARCH_PASSWORD:-{{ .Values.presets.discovery.services.elasticsearch.default_password }}}
          {{- if .Values.presets.discovery.collectionInterval }}
          collection_interval: "{{ .Values.presets.discovery.collectionInterval }}"
          {{- else }}
          collection_interval: 60s
          {{- end }}
{{- end }}

{{- if .Values.presets.discovery.services.kafka.enabled }}
      # Kafka Discovery
      kafkametrics:
        rule: |
          type == "hostport" and
          command matches "(?i)kafka.*" and
          not (command matches "coralogix|otel")
        config:
          brokers:
            - "`endpoint`"
          {{- if .Values.presets.discovery.collectionInterval }}
          collection_interval: "{{ .Values.presets.discovery.collectionInterval }}"
          {{- else }}
          collection_interval: 60s
          {{- end }}
{{- end }}

{{- if .Values.presets.discovery.services.cassandra.enabled }}
      # Cassandra Discovery (JMX)
      jmx/cassandra:
        rule: |
          type == "hostport" and
          command matches "(?i)cassandra.*" and
          not (command matches "coralogix|otel")
        config:
          jar_path: /opt/opentelemetry-java-contrib-jmx-metrics.jar
          endpoint: "service:jmx:rmi:///jndi/rmi://`endpoint`/jmxrmi"
          target_system: cassandra
          {{- if .Values.presets.discovery.collectionInterval }}
          collection_interval: "{{ .Values.presets.discovery.collectionInterval }}"
          {{- else }}
          collection_interval: 60s
          {{- end }}
{{- end }}
{{- end }}
