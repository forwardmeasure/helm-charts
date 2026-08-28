{{/*
Expand the name of the chart.
*/}}
{{- define "opa.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "opa.fullname" -}}
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

{{- define "opa.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (printf "%s-service-account" (include "opa.fullname" .)) .Values.serviceAccount.name }}
{{- else -}}
default
{{- end -}}
{{- end }}

{{/*
Common labels
*/}}
{{- define "opa.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{ include "opa.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "opa.selectorLabels" -}}
app.kubernetes.io/name: {{ include "opa.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/* Resolve an immutable image when a digest is configured. */}}
{{- define "opa.image" -}}
{{- if .Values.image.digest -}}
{{- printf "%s@%s" .Values.image.repository .Values.image.digest -}}
{{- else -}}
{{- printf "%s:%s" .Values.image.repository .Values.image.tag -}}
{{- end -}}
{{- end }}

{{/*
Resolve the policy-bundle ConfigMap name used by this chart.
*/}}
{{- define "opa.policiesConfigMapName" -}}
{{- printf "%s-policies" (include "opa.fullname" .) -}}
{{- end }}
