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
