{{/*
Expand the name of the chart.
*/}}
{{- define "opentelemetry-instrumentation-webhook.name" -}}
{{- default .Chart.Name .Values.nameOverride | lower | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "opentelemetry-instrumentation-webhook.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | lower | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride | lower }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | lower | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | lower | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "opentelemetry-instrumentation-webhook.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | lower | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels.
*/}}
{{- define "opentelemetry-instrumentation-webhook.labels" -}}
helm.sh/chart: {{ include "opentelemetry-instrumentation-webhook.chart" . }}
{{ include "opentelemetry-instrumentation-webhook.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels.
*/}}
{{- define "opentelemetry-instrumentation-webhook.selectorLabels" -}}
app.kubernetes.io/name: {{ include "opentelemetry-instrumentation-webhook.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Namespace to deploy namespaced resources.
*/}}
{{- define "opentelemetry-instrumentation-webhook.namespace" -}}
{{- default .Release.Namespace .Values.namespaceOverride }}
{{- end }}

{{/*
Create the instrumentation webhook manager ServiceAccount name.
*/}}
{{- define "opentelemetry-instrumentation-webhook.serviceAccountName" -}}
{{- $serviceAccount := .Values.manager.serviceAccount -}}
{{- if $serviceAccount.create }}
{{- default (include "opentelemetry-instrumentation-webhook.fullname" .) $serviceAccount.name }}
{{- else }}
{{- default "default" $serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Default instrumentation webhook admission settings.
*/}}
{{- define "opentelemetry-instrumentation-webhook.admissionWebhooks" -}}
{{- $defaults := dict "failurePolicy" "Ignore" "namespaceSelector" (dict) "objectSelector" (dict) "timeoutSeconds" 10 "namePrefix" "" "secretName" "" "autoGenerateCert" (dict "enabled" true "recreate" true) "cert_file" "" "key_file" "" "ca_file" "" -}}
{{- mustMergeOverwrite (deepCopy $defaults) (deepCopy (default dict .Values.admissionWebhooks)) | toYaml -}}
{{- end }}

{{/*
Create an ordered name for the instrumentation pod MutatingWebhookConfiguration.
*/}}
{{- define "opentelemetry-instrumentation-webhook.mutatingWebhookName" -}}
{{- $webhook := fromYaml (include "opentelemetry-instrumentation-webhook.admissionWebhooks" .) -}}
{{- printf "%s-%s" ($webhook.namePrefix | toString) (include "opentelemetry-instrumentation-webhook.fullname" .) | trimPrefix "-" }}
{{- end }}

{{/*
Return certificate and CA for the instrumentation pod webhook.
*/}}
{{- define "opentelemetry-instrumentation-webhook.webhookCert" -}}
{{- $webhook := fromYaml (include "opentelemetry-instrumentation-webhook.admissionWebhooks" .) -}}
{{- $name := include "opentelemetry-instrumentation-webhook.fullname" . -}}
{{- $secretName := default (printf "%s-controller-manager-service-cert" $name) $webhook.secretName -}}
{{- $caCertEnc := "" -}}
{{- $certCrtEnc := "" -}}
{{- $certKeyEnc := "" -}}
{{- if $webhook.autoGenerateCert.enabled -}}
{{- $prevSecret := lookup "v1" "Secret" (include "opentelemetry-instrumentation-webhook.namespace" .) $secretName -}}
{{- if and (not $webhook.autoGenerateCert.recreate) $prevSecret -}}
{{- $certCrtEnc = index $prevSecret "data" "tls.crt" -}}
{{- $certKeyEnc = index $prevSecret "data" "tls.key" -}}
{{- $caCertEnc = index $prevSecret "data" "ca.crt" -}}
{{- if not $caCertEnc -}}
{{- $prevHook := lookup "admissionregistration.k8s.io/v1" "MutatingWebhookConfiguration" "" (printf "%s-mutation" (include "opentelemetry-instrumentation-webhook.mutatingWebhookName" .)) -}}
{{- if not (eq (toString $prevHook) "<nil>") -}}
{{- $caCertEnc = (first $prevHook.webhooks).clientConfig.caBundle -}}
{{- end -}}
{{- end -}}
{{- else -}}
{{- $altNames := list (printf "%s.%s" $name (include "opentelemetry-instrumentation-webhook.namespace" .)) (printf "%s.%s.svc" $name (include "opentelemetry-instrumentation-webhook.namespace" .)) (printf "%s.%s.svc.cluster.local" $name (include "opentelemetry-instrumentation-webhook.namespace" .)) -}}
{{- $ca := genCA "opentelemetry-instrumentation-webhook-ca" 365 -}}
{{- $cert := genSignedCert $name nil $altNames 365 $ca -}}
{{- $certCrtEnc = b64enc $cert.Cert -}}
{{- $certKeyEnc = b64enc $cert.Key -}}
{{- $caCertEnc = b64enc $ca.Cert -}}
{{- end -}}
{{- else -}}
{{- $certCrtEnc = b64enc $webhook.cert_file -}}
{{- $certKeyEnc = b64enc $webhook.key_file -}}
{{- $caCertEnc = b64enc $webhook.ca_file -}}
{{- end -}}
{{- dict "crt" $certCrtEnc "key" $certKeyEnc "ca" $caCertEnc | toYaml -}}
{{- end }}

{{/*
Render static Instrumentation.spec for no-CRD instrumentation webhook manager config.
*/}}
{{- define "opentelemetry-instrumentation-webhook.instrumentationSpec" -}}
{{- $inst := .Values.instrumentation -}}
{{- $spec := deepCopy (default dict $inst.spec) -}}
{{- if and (hasKey $spec "apacheHttpd") (not (hasKey $spec "apachehttpd")) -}}
{{- $_ := set $spec "apachehttpd" (deepCopy (get $spec "apacheHttpd")) -}}
{{- $_ := unset $spec "apacheHttpd" -}}
{{- end -}}
{{- range $language, $image := (default dict $inst.images) -}}
{{- if $image -}}
{{- $specKey := $language -}}
{{- if eq $language "apacheHttpd" -}}
{{- $specKey = "apachehttpd" -}}
{{- end -}}
{{- $languageSpec := deepCopy (default dict (get $spec $specKey)) -}}
{{- if not (get $languageSpec "image") -}}
{{- $_ := set $languageSpec "image" $image -}}
{{- $_ := set $spec $specKey $languageSpec -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- tpl (toYaml $spec) . -}}
{{- end }}
