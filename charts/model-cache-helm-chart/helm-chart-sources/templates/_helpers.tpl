{{/*
Expand the name of the chart.
*/}}
{{- define "model-cache.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "model-cache.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name (include "model-cache.name" .) | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{/*
Common labels applied to all resources owned by this chart.
*/}}
{{- define "model-cache.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/name: {{ include "model-cache.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
{{- end }}

{{/*
PersistentVolume name — suffixed with release namespace to avoid collisions
when the chart is deployed into multiple namespaces pointing at the same
underlying storage backend.
*/}}
{{- define "model-cache.pvName" -}}
{{- printf "%s-%s-pv" .Release.Namespace .Release.Name }}
{{- end }}

{{/*
Validate that storageClass.provisioner is set when storageClass.create is true.
*/}}
{{- define "model-cache.validateStorageClass" -}}
{{- if and .Values.storageClass.create (empty .Values.storageClass.provisioner) }}
  {{- fail "storageClass.provisioner must be set when storageClass.create is true" }}
{{- end }}
{{- end }}

{{/*
Validate that persistentVolume.csi is set when persistentVolume.create is true.
*/}}
{{- define "model-cache.validatePersistentVolume" -}}
{{- if and .Values.persistentVolume.create (empty .Values.persistentVolume.csi) }}
  {{- fail "persistentVolume.csi must be set when persistentVolume.create is true" }}
{{- end }}
{{- end }}
