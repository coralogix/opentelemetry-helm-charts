{{/*
Default memory limiter configuration for OpenTelemetry Collector based on k8s resource limits.
*/}}
{{- define "opentelemetry-collector.memoryLimiter" -}}
# check_interval is the time between measurements of memory usage.
check_interval: 5s

# By default limit_mib is set to 80% of ".Values.resources.limits.memory"
limit_percentage: 80

# By default spike_limit_mib is set to 25% of ".Values.resources.limits.memory"
spike_limit_percentage: 25
{{- end }}

{{/*
Merge user supplied config into memory limiter config.
*/}}
{{- define "opentelemetry-collector.baseConfig" -}}
{{- $processorsConfig := get .Values.config "processors" }}
{{- if not $processorsConfig.memory_limiter }}
{{-   $_ := set $processorsConfig "memory_limiter" (include "opentelemetry-collector.memoryLimiter" . | fromYaml) }}
{{- end }}

{{- if .Values.useGOMEMLIMIT }}
  {{- if (((.Values.config).service).extensions) }}
    {{- $_ := set .Values.config.service "extensions" (without .Values.config.service.extensions "memory_ballast") }}
  {{- end}}
  {{- $_ := unset (.Values.config.extensions) "memory_ballast" }}
{{- else }}
  {{- $memoryBallastConfig := get .Values.config.extensions "memory_ballast" }}
  {{- if or (not $memoryBallastConfig) (not $memoryBallastConfig.size_in_percentage) }}
  {{-   $_ := set $memoryBallastConfig "size_in_percentage" 40 }}
  {{- end }}
{{- end }}

{{- .Values.config | toYaml }}
{{- end }}

{{/*
Build config file for daemonset OpenTelemetry Collector
*/}}
{{- define "opentelemetry-collector.daemonsetConfig" -}}
{{- $values := deepCopy .Values }}
{{- $data := dict "Values" $values | mustMergeOverwrite (deepCopy .) }}
{{- $config := include "opentelemetry-collector.baseConfig" $data | fromYaml }}
{{- if .Values.presets.logsCollection.enabled }}
{{- $config = (include "opentelemetry-collector.applyLogsCollectionConfig" (dict "Values" $data "config" $config) | fromYaml) }}
{{- end }}
{{- if .Values.presets.mysql.metrics.enabled }}
{{- $config = (include "opentelemetry-collector.applyMysqlConfig" (dict "Values" $data "config" $config) | fromYaml) }}
{{- end }}
{{- if .Values.presets.hostMetrics.enabled }}
{{- $config = (include "opentelemetry-collector.applyHostMetricsConfig" (dict "Values" $data "config" $config) | fromYaml) }}
{{- end }}
{{- if .Values.presets.kubeletMetrics.enabled }}
{{- $config = (include "opentelemetry-collector.applyKubeletMetricsConfig" (dict "Values" $data "config" $config) | fromYaml) }}
{{- end }}
{{- if .Values.presets.kubernetesAttributes.enabled }}
{{- $config = (include "opentelemetry-collector.applyKubernetesAttributesConfig" (dict "Values" $data "config" $config) | fromYaml) }}
{{- end }}
{{- if .Values.presets.clusterMetrics.enabled }}
{{- $config = (include "opentelemetry-collector.applyClusterMetricsConfig" (dict "Values" $data "config" $config) | fromYaml) }}
{{- end }}
{{- if .Values.presets.metadata.enabled }}
{{- $config = (include "opentelemetry-collector.applyMetadataConfig" (dict "Values" $data "config" $config) | fromYaml) }}
{{- end }}
{{- tpl (toYaml $config) . }}
{{- end }}

{{/*
Build config file for deployment OpenTelemetry Collector
*/}}
{{- define "opentelemetry-collector.deploymentConfig" -}}
{{- $values := deepCopy .Values }}
{{- $data := dict "Values" $values | mustMergeOverwrite (deepCopy .) }}
{{- $config := include "opentelemetry-collector.baseConfig" $data | fromYaml }}
{{- if .Values.presets.logsCollection.enabled }}
{{- $config = (include "opentelemetry-collector.applyLogsCollectionConfig" (dict "Values" $data "config" $config) | fromYaml) }}
{{- end }}
{{- if .Values.presets.mysql.metrics.enabled }}
{{- $config = (include "opentelemetry-collector.applyMysqlConfig" (dict "Values" $data "config" $config) | fromYaml) }}
{{- end }}
{{- if .Values.presets.hostMetrics.enabled }}
{{- $config = (include "opentelemetry-collector.applyHostMetricsConfig" (dict "Values" $data "config" $config) | fromYaml) }}
{{- end }}
{{- if .Values.presets.kubeletMetrics.enabled }}
{{- $config = (include "opentelemetry-collector.applyKubeletMetricsConfig" (dict "Values" $data "config" $config) | fromYaml) }}
{{- end }}
{{- if .Values.presets.kubernetesAttributes.enabled }}
{{- $config = (include "opentelemetry-collector.applyKubernetesAttributesConfig" (dict "Values" $data "config" $config) | fromYaml) }}
{{- end }}
{{- if .Values.presets.kubernetesEvents.enabled }}
{{- $config = (include "opentelemetry-collector.applyKubernetesEventsConfig" (dict "Values" $data "config" $config) | fromYaml) }}
{{- end }}
{{- if .Values.presets.clusterMetrics.enabled }}
{{- $config = (include "opentelemetry-collector.applyClusterMetricsConfig" (dict "Values" $data "config" $config) | fromYaml) }}
{{- end }}
{{- if .Values.presets.kubernetesExtraMetrics.enabled }}
{{- $config = (include "opentelemetry-collector.applyKubernetesExtraMetrics" (dict "Values" $data "config" $config) | fromYaml) }}
{{- end }}
{{- if .Values.presets.metadata.enabled }}
{{- $config = (include "opentelemetry-collector.applyMetadataConfig" (dict "Values" $data "config" $config) | fromYaml) }}
{{- end }}
{{- tpl (toYaml $config) . }}
{{- end }}

{{- define "opentelemetry-collector.applyHostMetricsConfig" -}}
{{- $config := mustMergeOverwrite (include "opentelemetry-collector.hostMetricsConfig" .Values | fromYaml) .config }}
{{- $_ := set $config.service.pipelines.metrics "receivers" (append $config.service.pipelines.metrics.receivers "hostmetrics" | uniq)  }}
{{- $config | toYaml }}
{{- end }}

{{- define "opentelemetry-collector.hostMetricsConfig" -}}
receivers:
  hostmetrics:
    {{- if not .Values.isWindows }}
    root_path: /hostfs
    {{- end }}
    collection_interval: 10s
    scrapers:
        cpu:
          metrics:
            system.cpu.utilization:
              enabled: true
        load:
        memory:
          metrics:
            system.memory.utilization:
              enabled: true
        disk:
        filesystem:
          {{- if not .Values.isWindows }}
          exclude_mount_points:
            mount_points:
              - /dev/*
              - /proc/*
              - /sys/*
              - /run/k3s/containerd/*
              - /run/containerd/runc/*
              - /var/lib/docker/*
              - /var/lib/kubelet/*
              - /snap/*
            match_type: regexp
          exclude_fs_types:
            fs_types:
              - autofs
              - binfmt_misc
              - bpf
              - cgroup2
              - configfs
              - debugfs
              - devpts
              - devtmpfs
              - fusectl
              - hugetlbfs
              - iso9660
              - mqueue
              - nsfs
              - overlay
              - proc
              - procfs
              - pstore
              - rpc_pipefs
              - securityfs
              - selinuxfs
              - squashfs
              - sysfs
              - tracefs
            match_type: strict
          {{- end }}
        network:
{{- end }}

{{- define "opentelemetry-collector.applyClusterMetricsConfig" -}}
{{- $config := mustMergeOverwrite (include "opentelemetry-collector.clusterMetricsConfig" .Values | fromYaml) .config }}
{{- $_ := set $config.service.pipelines.metrics "receivers" (append $config.service.pipelines.metrics.receivers "k8s_cluster" | uniq)  }}
{{- $config | toYaml }}
{{- end }}

{{- define "opentelemetry-collector.clusterMetricsConfig" -}}
receivers:
  k8s_cluster:
    collection_interval: 10s
{{- end }}

{{- define "opentelemetry-collector.applyKubeletMetricsConfig" -}}
{{- $config := mustMergeOverwrite (include "opentelemetry-collector.kubeletMetricsConfig" .Values | fromYaml) .config }}
{{- $_ := set $config.service.pipelines.metrics "receivers" (append $config.service.pipelines.metrics.receivers "kubeletstats" | uniq)  }}
{{- $config | toYaml }}
{{- end }}

{{- define "opentelemetry-collector.kubeletMetricsConfig" -}}
receivers:
  kubeletstats:
    collection_interval: 20s
    insecure_skip_verify: true
    auth_type: "serviceAccount"
    endpoint: "${env:K8S_NODE_NAME}:10250"
{{- end }}

{{- define "opentelemetry-collector.applyLogsCollectionConfig" -}}
{{- $config := mustMergeOverwrite (include "opentelemetry-collector.logsCollectionConfig" .Values | fromYaml) .config }}
{{- $_ := set $config.service.pipelines.logs "receivers" (append $config.service.pipelines.logs.receivers "filelog" | uniq)  }}
{{- if .Values.Values.presets.logsCollection.storeCheckpoints}}
{{- $_ := set $config.service "extensions" (append $config.service.extensions "file_storage" | uniq)  }}
{{- end }}
{{- $config | toYaml }}
{{- end }}

{{- define "opentelemetry-collector.logsCollectionConfig" -}}
{{- if .Values.presets.logsCollection.storeCheckpoints }}
extensions:
  file_storage:
    directory: /var/lib/otelcol
{{- end }}
receivers:
  filelog:
    {{- if .Values.isWindows }}
    include: ["C:\\var\\log\\pods\\*\\*\\*.log"]
    {{- else }}
    include: [ /var/log/pods/*/*/*.log ]
    {{- end }}
    {{- if .Values.presets.logsCollection.includeCollectorLogs }}
    exclude: []
    {{- else }}
    {{- if .Values.isWindows }}
    exclude: [ "C:\\var\\log\\pods\\{{ .Release.Namespace }}_{{ include "opentelemetry-collector.fullname" . }}*_*\\{{ include "opentelemetry-collector.lowercase_chartname" . }}\\*.log" ]
    {{- else }}
    # Exclude collector container's logs. The file format is /var/log/pods/<namespace_name>_<pod_name>_<pod_uid>/<container_name>/<run_id>.log
    exclude: [ /var/log/pods/{{ .Release.Namespace }}_{{ include "opentelemetry-collector.fullname" . }}*_*/{{ include "opentelemetry-collector.lowercase_chartname" . }}/*.log ]
    {{- end }}
    {{- end }}
    start_at: beginning
    {{- if .Values.presets.logsCollection.storeCheckpoints}}
    storage: file_storage
    {{- end }}
    include_file_path: true
    include_file_name: false
    operators:
      # Find out which format is used by kubernetes
      - type: router
        id: get-format
        routes:
          - output: parser-docker
            expr: 'body matches "^\\{"'
          - output: parser-crio
            expr: 'body matches "^[^ Z]+ "'
          - output: parser-containerd
            expr: 'body matches "^[^ Z]+Z"'
      # Parse CRI-O format
      - type: regex_parser
        id: parser-crio
        regex: '^(?P<time>[^ Z]+) (?P<stream>stdout|stderr) (?P<logtag>[^ ]*) ?(?P<log>.*)$'
        timestamp:
          parse_from: attributes.time
          layout_type: gotime
          layout: '2006-01-02T15:04:05.999999999Z07:00'
      - type: recombine
        id: crio-recombine
        output: extract_metadata_from_filepath
        combine_field: attributes.log
        source_identifier: attributes["log.file.path"]
        is_last_entry: "attributes.logtag == 'F'"
        combine_with: ""
        max_log_size: {{ $.Values.presets.logsCollection.maxRecombineLogSize }}
      # Parse CRI-Containerd format
      - type: regex_parser
        id: parser-containerd
        regex: '^(?P<time>[^ ^Z]+Z) (?P<stream>stdout|stderr) (?P<logtag>[^ ]*) ?(?P<log>.*)$'
        timestamp:
          parse_from: attributes.time
          layout: '%Y-%m-%dT%H:%M:%S.%LZ'
      - type: recombine
        id: containerd-recombine
        output: extract_metadata_from_filepath
        combine_field: attributes.log
        source_identifier: attributes["log.file.path"]
        is_last_entry: "attributes.logtag == 'F'"
        combine_with: ""
        max_log_size: {{ $.Values.presets.logsCollection.maxRecombineLogSize }}
      # Parse Docker format
      - type: json_parser
        id: parser-docker
        timestamp:
          parse_from: attributes.time
          layout: '%Y-%m-%dT%H:%M:%S.%LZ'
      - type: recombine
        id: docker-recombine
        output: extract_metadata_from_filepath
        combine_field: attributes.log
        source_identifier: attributes["log.file.path"]
        is_last_entry: attributes.log endsWith "\n"
        combine_with: ""
        max_log_size: {{ $.Values.presets.logsCollection.maxRecombineLogSize }}
      # Extract metadata from file path
      - type: regex_parser
        id: extract_metadata_from_filepath
        {{- if .Values.isWindows }}
        regex: '^C:\\var\\log\\pods\\(?P<namespace>[^_]+)_(?P<pod_name>[^_]+)_(?P<uid>[^\/]+)\\(?P<container_name>[^\._]+)\\(?P<restart_count>\d+)\.log$'
        {{- else }}
        regex: '^.*\/(?P<namespace>[^_]+)_(?P<pod_name>[^_]+)_(?P<uid>[a-f0-9\-]+)\/(?P<container_name>[^\._]+)\/(?P<restart_count>\d+)\.log$'
        {{- end }}
        parse_from: attributes["log.file.path"]
      # Rename attributes
      - type: move
        from: attributes.stream
        to: attributes["log.iostream"]
      - type: move
        from: attributes.container_name
        to: resource["k8s.container.name"]
      - type: move
        from: attributes.namespace
        to: resource["k8s.namespace.name"]
      - type: move
        from: attributes.pod_name
        to: resource["k8s.pod.name"]
      - type: move
        from: attributes.restart_count
        to: resource["k8s.container.restart_count"]
      - type: move
        from: attributes.uid
        to: resource["k8s.pod.uid"]
      # Clean up log body
      - type: move
        from: attributes.log
        to: body
      {{- if .Values.presets.logsCollection.extraFilelogOperators }}
      {{- .Values.presets.logsCollection.extraFilelogOperators | toYaml | nindent 6 }}
      {{- end }}
{{- end }}

{{- define "opentelemetry-collector.applyKubernetesExtraMetrics" -}}
{{- $config := mustMergeOverwrite (include "opentelemetry-collector.kubernetesExtraMetricsConfig" .Values | fromYaml) .config }}
{{- $_ := set $config.service.pipelines.metrics "receivers" (append $config.service.pipelines.metrics.receivers "receiver_creator/ksm_prometheus" | uniq)  }}
{{- $_ := set $config.service.pipelines.metrics "receivers" (append $config.service.pipelines.metrics.receivers "prometheus/k8s_extra_metrics" | uniq)  }}
{{- $_ := set $config.service.pipelines.metrics "processors" (append $config.service.pipelines.metrics.processors "filter/k8s_extra_metrics" | uniq)  }}
{{- $_ := set $config.service "extensions" (append $config.service.extensions "k8s_observer" | uniq)  }}
{{- $config | toYaml }}
{{- end }}

{{- define "opentelemetry-collector.kubernetesExtraMetricsConfig" -}}
extensions:
  k8s_observer:
    auth_type: serviceAccount
    observe_pods: true
receivers:
  receiver_creator/ksm_prometheus:
    watch_observers: [k8s_observer]
    receivers:
      prometheus_simple:
        rule: type == "port" && port == 8080 && pod.name contains "{{tpl .Values.presets.kubernetesExtraMetrics.kubeStateMetricsName . }}"
        config:
          endpoint: '`endpoint`'
  prometheus/k8s_extra_metrics:
    config:
      scrape_configs:
      - job_name: kubernetes-apiserver
        honor_timestamps: true
        scheme: https
        bearer_token_file: /var/run/secrets/kubernetes.io/serviceaccount/token
        tls_config:
          ca_file: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
          insecure_skip_verify: true
        kubernetes_sd_configs:
        - role: endpoints
        relabel_configs:
          - source_labels:
              [
                __meta_kubernetes_namespace,
                __meta_kubernetes_service_name,
                __meta_kubernetes_endpoint_port_name,
              ]
            action: keep
            regex: default;kubernetes;https
      - job_name: kubernetes-cadvisor
        honor_timestamps: true
        metrics_path: /metrics/cadvisor
        scheme: https
        bearer_token_file: /var/run/secrets/kubernetes.io/serviceaccount/token
        tls_config:
          ca_file: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
          insecure_skip_verify: true
        kubernetes_sd_configs:
        - role: node
        relabel_configs:
          - action: labelmap
            regex: __meta_kubernetes_node_label_(.+)
processors:
  filter/k8s_extra_metrics:
    metrics:
      metric:
        - 'resource.attributes["service.name"] == "kubernetes-apiserver" and name != "kubernetes_build_info"'
        - 'resource.attributes["service.name"] == "kubernetes-cadvisor" and
          (name != "container_fs_writes_total" and name != "container_fs_reads_total" and
          name != "container_fs_writes_bytes_total" and name != "container_fs_reads_bytes_total" and
          name != "container_fs_usage_bytes")'
{{- end }}

{{- define "opentelemetry-collector.applyMysqlConfig" -}}
{{- $config := mustMergeOverwrite (include "opentelemetry-collector.mysqlConfig" .Values | fromYaml) .config }}
{{- $_ := set $config.service.pipelines.metrics "receivers" (append $config.service.pipelines.metrics.receivers "receiver_creator/mysql" | uniq)  }}
{{- $_ := set $config.service "extensions" (append $config.service.extensions "k8s_observer" | uniq)  }}
{{- $config | toYaml }}
{{- end }}

{{- define "opentelemetry-collector.mysqlConfig" -}}
{{- $instances := deepCopy .Values.presets.mysql.metrics.instances }}
{{- range $key, $instance := $instances }}
extensions:
  k8s_observer:
    auth_type: serviceAccount
    node: ${env:K8S_NODE_NAME}
    observe_pods: true
receivers:
  receiver_creator/mysql:
    watch_observers: [k8s_observer]
    receivers:
      mysql:
        rule: type == "port" && port == {{ $instance.port | default 3306 }} {{- range $name, $value := $instance.labelSelectors }} && pod.labels["{{ $name }}"] == "{{ $value }}" {{- end }}
        config:
          username: {{ $instance.username }}
          password: {{ $instance.password }}
          collection_interval: 10s
          statement_events:
            digest_text_limit: 120
            time_limit: 24h
            limit: 250
          metrics:
            mysql.query.count:
              enabled: true
            mysql.query.slow.count:
              enabled: true
            mysql.joins:
              enabled: true
            mysql.sorts:
              enabled: true
            mysql.connection.errors:
              enabled: true
            mysql.commands:
              enabled: true
            mysql.client.network.io:
              enabled: true
            mysql.table_open_cache:
              enabled: true

{{- end }}
{{- end }}

{{- define "opentelemetry-collector.applyKubernetesAttributesConfig" -}}
{{- $config := mustMergeOverwrite (include "opentelemetry-collector.kubernetesAttributesConfig" .Values | fromYaml) .config }}
{{- if and ($config.service.pipelines.logs) (not (has "transform/k8s_attributes" $config.service.pipelines.logs.processors)) }}
{{- $_ := set $config.service.pipelines.logs "processors" (append $config.service.pipelines.logs.processors "transform/k8s_attributes" | uniq)  }}
{{- end }}
{{- if and ($config.service.pipelines.logs) (not (has "k8sattributes" $config.service.pipelines.logs.processors)) }}
{{- $_ := set $config.service.pipelines.logs "processors" (prepend $config.service.pipelines.logs.processors "k8sattributes" | uniq)  }}
{{- end }}
{{- if and ($config.service.pipelines.metrics) (not (has "transform/k8s_attributes" $config.service.pipelines.metrics.processors)) }}
{{- $_ := set $config.service.pipelines.metrics "processors" (append $config.service.pipelines.metrics.processors "transform/k8s_attributes" | uniq)  }}
{{- end }}
{{- if and ($config.service.pipelines.metrics) (not (has "k8sattributes" $config.service.pipelines.metrics.processors)) }}
{{- $_ := set $config.service.pipelines.metrics "processors" (prepend $config.service.pipelines.metrics.processors "k8sattributes" | uniq)  }}
{{- end }}
{{- if and ($config.service.pipelines.traces) (not (has "transform/k8s_attributes" $config.service.pipelines.traces.processors)) }}
{{- $_ := set $config.service.pipelines.traces "processors" (append $config.service.pipelines.traces.processors "transform/k8s_attributes" | uniq)  }}
{{- end }}
{{- if and ($config.service.pipelines.traces) (not (has "k8sattributes" $config.service.pipelines.traces.processors)) }}
{{- $_ := set $config.service.pipelines.traces "processors" (prepend $config.service.pipelines.traces.processors "k8sattributes" | uniq)  }}
{{- end }}
{{- $config | toYaml }}
{{- end }}

{{- define "opentelemetry-collector.applyMetadataConfig" -}}
{{- $config := mustMergeOverwrite (include "opentelemetry-collector.metadataConfig" .Values | fromYaml) .config }}
{{- if and ($config.service.pipelines.logs) (not (has "resource/metadata" $config.service.pipelines.logs.processors)) }}
{{- $_ := set $config.service.pipelines.logs "processors" (prepend $config.service.pipelines.logs.processors "resource/metadata" | uniq)  }}
{{- end }}
{{- if and ($config.service.pipelines.metrics) (not (has "resource/metadata" $config.service.pipelines.metrics.processors)) }}
{{- $_ := set $config.service.pipelines.metrics "processors" (prepend $config.service.pipelines.metrics.processors "resource/metadata" | uniq)  }}
{{- end }}
{{- if and ($config.service.pipelines.traces) (not (has "resource/metadata" $config.service.pipelines.traces.processors)) }}
{{- $_ := set $config.service.pipelines.traces "processors" (prepend $config.service.pipelines.traces.processors "resource/metadata" | uniq)  }}
{{- end }}
{{- $config | toYaml }}
{{- end }}

{{- define "opentelemetry-collector.metadataConfig" -}}
processors:
  resource/metadata:
    attributes:
      {{- if .Values.presets.metadata.clusterName }}
      - key: k8s.cluster.name
        value: "{{ .Values.presets.metadata.clusterName }}"
        action: upsert
      {{- end }}
      {{- if .Values.presets.metadata.integrationName }}
      - key: cx.otel_integration.name
        value: "{{ .Values.presets.metadata.integrationName }}"
        action: upsert
      {{- end }}
{{- end }}

{{- define "opentelemetry-collector.kubernetesAttributesConfig" -}}
processors:
  k8sattributes:
  {{- if eq .Values.mode "daemonset" }}
    filter:
      node_from_env_var: K8S_NODE_NAME
  {{- end }}
    passthrough: false
    pod_association:
    - sources:
      - from: resource_attribute
        name: k8s.pod.ip
    - sources:
      - from: resource_attribute
        name: k8s.pod.uid
    - sources:
      - from: connection
    extract:
      metadata:
        - "k8s.namespace.name"
        - "k8s.replicaset.name"
        - "k8s.statefulset.name"
        - "k8s.daemonset.name"
        - "k8s.cronjob.name"
        - "k8s.job.name"
        - "k8s.node.name"
        - "k8s.pod.name"
        - "k8s.pod.uid"
        - "k8s.pod.start_time"
      {{- if .Values.presets.kubernetesAttributes.extractAllPodLabels }}
      labels:
        - tag_name: $$1
          key_regex: (.*)
          from: pod
      {{- end }}
      {{- if .Values.presets.kubernetesAttributes.extractAllPodAnnotations }}
      annotations:
        - tag_name: $$1
          key_regex: (.*)
          from: pod
      {{- end }}
  transform/k8s_attributes:
    metric_statements:
    - context: resource
      statements:
      - set(attributes["k8s.deployment.name"], attributes["k8s.replicaset.name"])
      - replace_pattern(attributes["k8s.deployment.name"], "^(.*)-[0-9a-zA-Z]+$", "$$1")
      - delete_key(attributes, "k8s.replicaset.name")
    trace_statements:
    - context: resource
      statements:
      - set(attributes["k8s.deployment.name"], attributes["k8s.replicaset.name"])
      - replace_pattern(attributes["k8s.deployment.name"], "^(.*)-[0-9a-zA-Z]+$", "$$1")
      - delete_key(attributes, "k8s.replicaset.name")
    log_statements:
    - context: resource
      statements:
      - set(attributes["k8s.deployment.name"], attributes["k8s.replicaset.name"])
      - replace_pattern(attributes["k8s.deployment.name"], "^(.*)-[0-9a-zA-Z]+$", "$$1")
      - delete_key(attributes, "k8s.replicaset.name")
{{- end }}

{{/* Build the list of port for service */}}
{{- define "opentelemetry-collector.servicePortsConfig" -}}
{{- $ports := deepCopy .Values.ports }}
{{- range $key, $port := $ports }}
{{- if $port.enabled }}
- name: {{ $key }}
  port: {{ $port.servicePort }}
  targetPort: {{ $port.containerPort }}
  protocol: {{ $port.protocol }}
  {{- if $port.appProtocol }}
  appProtocol: {{ $port.appProtocol }}
  {{- end }}
{{- if $port.nodePort }}
  nodePort: {{ $port.nodePort }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}

{{/* Build the list of port for pod */}}
{{- define "opentelemetry-collector.podPortsConfig" -}}
{{- $ports := deepCopy .Values.ports }}
{{- range $key, $port := $ports }}
{{- if $port.enabled }}
- name: {{ $key }}
  containerPort: {{ $port.containerPort }}
  protocol: {{ $port.protocol }}
  {{- if and $.isAgent $port.hostPort }}
  hostPort: {{ $port.hostPort }}
  {{- end }}
{{- end }}
{{- end }}
{{- end }}

{{- define "opentelemetry-collector.applyKubernetesEventsConfig" -}}
{{- $config := mustMergeOverwrite (include "opentelemetry-collector.kubernetesEventsConfig" .Values | fromYaml) .config }}
{{- $_ := set $config.service.pipelines.logs "receivers" (append $config.service.pipelines.logs.receivers "k8sobjects" | uniq)  }}
{{- $config | toYaml }}
{{- end }}

{{- define "opentelemetry-collector.kubernetesEventsConfig" -}}
receivers:
  k8sobjects:
    objects:
      - name: events
        mode: "watch"
        group: "events.k8s.io"
        exclude_watch_type:
          - "DELETED"
{{- end }}
