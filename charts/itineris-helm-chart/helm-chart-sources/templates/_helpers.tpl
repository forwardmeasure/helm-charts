{{/*
Expand the name of the chart.
*/}}
{{- define "itineris.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "itineris.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart label.
*/}}
{{- define "itineris.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels.
*/}}
{{- define "itineris.labels" -}}
helm.sh/chart: {{ include "itineris.chart" . }}
{{ include "itineris.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels.
*/}}
{{- define "itineris.selectorLabels" -}}
app.kubernetes.io/name: {{ include "itineris.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Service account name.
*/}}
{{- define "itineris.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "itineris.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Image reference — prefers digest over tag if both are set.
Usage: {{ include "itineris.image" . }}
*/}}
{{- define "itineris.image" -}}
{{- $registry := .Values.image.registry -}}
{{- $repository := .Values.image.repository -}}
{{- $digest := .Values.image.digest | default "" -}}
{{- $tag := .Values.image.tag | default .Chart.AppVersion -}}
{{- if $digest }}
{{- printf "%s/%s@%s" $registry $repository $digest }}
{{- else }}
{{- printf "%s/%s:%s" $registry $repository $tag }}
{{- end }}
{{- end }}

{{/* Runner image reference — prefers digest over tag if both are set. */}}
{{- define "itineris.analyticsImage" -}}
{{- $registry := .Values.image.registry -}}
{{- $repository := .Values.analyticsJob.image.repository -}}
{{- $digest := .Values.analyticsJob.image.digest | default "" -}}
{{- $tag := .Values.analyticsJob.image.tag | default .Chart.AppVersion -}}
{{- if $digest }}
{{- printf "%s/%s@%s" $registry $repository $digest }}
{{- else }}
{{- printf "%s/%s:%s" $registry $repository $tag }}
{{- end }}
{{- end }}

{{- define "itineris.analyticsServiceAccountName" -}}
{{- default (printf "%s-analytics" (include "itineris.fullname" .) | trunc 63 | trimSuffix "-") .Values.analytics.serviceAccount.name -}}
{{- end }}

{{- define "itineris.migrationsImage" -}}

{{- $image := .Values.controlPlane.migrations.image -}}
{{- if $image.digest -}}
{{- printf "%s/%s@%s" .Values.image.registry $image.repository $image.digest -}}
{{- else -}}
{{- printf "%s/%s:%s" .Values.image.registry $image.repository ($image.tag | default .Chart.AppVersion) -}}
{{- end -}}
{{- end }}

{{/* Certificate files and passwords share one policy for server and direct worker manifests. */}}
{{- define "itineris.backendTlsEnv" -}}
{{- $backend := .backend -}}
{{- $tls := .tls -}}
{{- if and $tls.clientAuthentication (or (not $tls.enabled) (not $tls.secretName)) -}}
{{- fail "TLS client authentication requires TLS enabled and a certificate Secret" -}}
{{- end }}
- name: {{ printf "ITINERIS_%s_SSL_ENABLED" $backend }}
  value: {{ $tls.enabled | quote }}
{{- if eq $backend "CASSANDRA" }}
- name: ITINERIS_CASSANDRA_SSL_HOSTNAME_VALIDATION
  value: {{ $tls.hostnameValidation | quote }}
- name: ITINERIS_CASSANDRA_SSL_CLIENT_AUTHENTICATION
  value: {{ $tls.clientAuthentication | quote }}
{{- end }}
{{- if and $tls.enabled $tls.secretName }}
- name: {{ printf "ITINERIS_%s_TRUSTSTORE_PATH" $backend }}
  value: {{ printf "%s/%s" $tls.mountPath $tls.truststoreKey | quote }}
- name: {{ printf "ITINERIS_%s_TRUSTSTORE_PASSWORD" $backend }}
  valueFrom:
    secretKeyRef:
      name: {{ $tls.secretName }}
      key: {{ $tls.truststorePasswordKey }}
{{- if .analytics }}
- name: {{ printf "ITINERIS_ANALYTICS_%s_TRUSTSTORE_PASSWORD_REF" $backend }}
  value: {{ printf "%s/%s" $tls.secretName $tls.truststorePasswordKey | quote }}
- name: {{ printf "itineris.analytics.secret-volumes.%s-tls" (lower $backend) }}
  value: {{ printf "%s:%s" $tls.secretName $tls.mountPath | quote }}
{{- end }}
{{- if $tls.clientAuthentication }}
- name: {{ printf "ITINERIS_%s_KEYSTORE_PATH" $backend }}
  value: {{ printf "%s/%s" $tls.mountPath $tls.keystoreKey | quote }}
{{- range $name, $key := dict "KEYSTORE_PASSWORD" $tls.keystorePasswordKey "KEY_PASSWORD" $tls.keyPasswordKey }}
- name: {{ printf "ITINERIS_%s_%s" $backend $name }}
  valueFrom:
    secretKeyRef:
      name: {{ $tls.secretName }}
      key: {{ $key }}
{{- if $.analytics }}
- name: {{ printf "ITINERIS_ANALYTICS_%s_%s_REF" $backend $name }}
  value: {{ printf "%s/%s" $tls.secretName $key | quote }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}

{{- define "itineris.tlsMounts" -}}
{{- range $backend, $tls := dict "cassandra" .Values.cql.ssl "opensearch" .Values.opensearch.ssl }}
{{- if and $tls.enabled $tls.secretName }}
- name: {{ $backend }}-tls
  mountPath: {{ $tls.mountPath | quote }}
  readOnly: true
{{- end }}
{{- end }}
{{- end }}

{{- define "itineris.tlsVolumes" -}}
{{- range $backend, $tls := dict "cassandra" .Values.cql.ssl "opensearch" .Values.opensearch.ssl }}
{{- if and $tls.enabled $tls.secretName }}
- name: {{ $backend }}-tls
  secret:
    secretName: {{ $tls.secretName }}
{{- end }}
{{- end }}
{{- end }}

{{/* Spark receives only Secret references and paths here, never password values. */}}
{{- define "itineris.directSparkConfiguration" -}}
{{ .Values.analyticsJob.sparkConfigurationProperties }}
{{- range $backend, $tls := dict "cassandra" .Values.cql.ssl "opensearch" .Values.opensearch.ssl }}
{{- if and $tls.enabled $tls.secretName }}
{{ printf "\nspark.kubernetes.executor.volumes.secret.%s-tls.options.secretName=%s" $backend $tls.secretName }}
{{ printf "\nspark.kubernetes.executor.volumes.secret.%s-tls.mount.path=%s" $backend $tls.mountPath }}
{{ printf "\nspark.kubernetes.executor.volumes.secret.%s-tls.mount.readOnly=true" $backend }}
{{- end }}
{{- end }}
{{- end }}
