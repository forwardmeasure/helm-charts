{{- /*
Common template helpers for the docling-serve Helm chart.
*/ -}}

{{- define "docling-serve.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "docling-serve.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "docling-serve.chart" -}}
{{- printf "%s-%s" .Chart.Name (.Chart.Version | replace "+" "_") -}}
{{- end -}}

{{- define "docling-serve.labels" -}}
helm.sh/chart: {{ include "docling-serve.chart" . }}
app.kubernetes.io/name: {{ include "docling-serve.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "docling-serve.selectorLabels" -}}
app.kubernetes.io/name: {{ include "docling-serve.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}