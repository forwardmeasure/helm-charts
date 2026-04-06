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
PersistentVolume name.

This chart never derives PV names. The name must be explicitly configured.
*/}}
{{- define "model-cache.pvName" -}}
{{- required "persistentVolume.name must be set when persistentVolume.create is true" .Values.persistentVolume.name | trunc 253 | trimSuffix "-" -}}
{{- end }}

{{/*
PVC target PV name.

Resolution order:
1. persistentVolumeClaim.existingVolumeName
2. persistentVolume.name

No derived fallback is used.
*/}}
{{- define "model-cache.pvcVolumeName" -}}
{{- if .Values.persistentVolumeClaim.existingVolumeName }}
{{- .Values.persistentVolumeClaim.existingVolumeName | trunc 253 | trimSuffix "-" }}
{{- else }}
{{- required "persistentVolumeClaim.existingVolumeName must be set when persistentVolume.create is false" .Values.persistentVolume.name | trunc 253 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{/*
Validate StorageClass settings.
*/}}
{{- define "model-cache.validateStorageClass" -}}
{{- if .Values.storageClass.create }}
  {{- if empty .Values.storageClass.name }}
    {{- fail "storageClass.name must be set when storageClass.create is true" }}
  {{- end }}
  {{- if empty .Values.storageClass.provisioner }}
    {{- fail "storageClass.provisioner must be set when storageClass.create is true" }}
  {{- end }}
{{- end }}
{{- end }}

{{/*
Validate PersistentVolume settings.
*/}}
{{- define "model-cache.validatePersistentVolume" -}}
{{- if .Values.persistentVolume.create }}
  {{- if empty .Values.persistentVolume.name }}
    {{- fail "persistentVolume.name must be set when persistentVolume.create is true" }}
  {{- end }}
  {{- if empty .Values.size }}
    {{- fail "size must be set when persistentVolume.create is true" }}
  {{- end }}
  {{- if empty .Values.storageClass.name }}
    {{- fail "storageClass.name must be set when persistentVolume.create is true" }}
  {{- end }}
  {{- if empty .Values.persistentVolume.accessMode }}
    {{- fail "persistentVolume.accessMode must be set when persistentVolume.create is true" }}
  {{- end }}
  {{- if empty .Values.persistentVolume.csi.driver }}
    {{- fail "persistentVolume.csi.driver must be set when persistentVolume.create is true" }}
  {{- end }}
  {{- if empty .Values.persistentVolume.csi.volumeHandle }}
    {{- fail "persistentVolume.csi.volumeHandle must be set when persistentVolume.create is true" }}
  {{- end }}
  {{- if .Values.persistentVolumeClaim.create }}
    {{- if empty .Release.Namespace }}
      {{- fail "persistentVolumeClaim.create is true, but .Release.Namespace is empty. Set a release namespace or disable persistentVolumeClaim.create." }}
    {{- end }}
    {{- if empty .Values.persistentVolumeClaim.name }}
      {{- fail "persistentVolumeClaim.name must be set when persistentVolumeClaim.create is true" }}
    {{- end }}
  {{- end }}
{{- end }}
{{- end }}

{{/*
Validate PersistentVolumeClaim settings.
*/}}
{{- define "model-cache.validatePersistentVolumeClaim" -}}
{{- if .Values.persistentVolumeClaim.create }}
  {{- if empty .Release.Namespace }}
    {{- fail "persistentVolumeClaim.create is true, but .Release.Namespace is empty. Set a release namespace or disable persistentVolumeClaim.create." }}
  {{- end }}
  {{- if empty .Values.persistentVolumeClaim.name }}
    {{- fail "persistentVolumeClaim.name must be set when persistentVolumeClaim.create is true" }}
  {{- end }}
  {{- if empty .Values.persistentVolumeClaim.accessMode }}
    {{- fail "persistentVolumeClaim.accessMode must be set when persistentVolumeClaim.create is true" }}
  {{- end }}
  {{- if empty .Values.storageClass.name }}
    {{- fail "storageClass.name must be set when persistentVolumeClaim.create is true" }}
  {{- end }}
  {{- if empty .Values.size }}
    {{- fail "size must be set when persistentVolumeClaim.create is true" }}
  {{- end }}
  {{- if and .Values.persistentVolume.create (empty .Values.persistentVolume.name) }}
    {{- fail "persistentVolume.name must be set when persistentVolume.create is true and persistentVolumeClaim.create is true" }}
  {{- end }}
  {{- if and (not .Values.persistentVolume.create) (empty .Values.persistentVolumeClaim.existingVolumeName) }}
    {{- fail "persistentVolumeClaim.existingVolumeName must be set when persistentVolumeClaim.create is true and persistentVolume.create is false" }}
  {{- end }}
{{- end }}
{{- end }}

{{/*
Validate ServiceAccount settings.
*/}}
{{- define "model-cache.validateServiceAccount" -}}
{{- if .Values.serviceAccount.create }}
  {{- if empty .Release.Namespace }}
    {{- fail "serviceAccount.create is true, but .Release.Namespace is empty. Set a release namespace or disable serviceAccount.create." }}
  {{- end }}
  {{- if empty .Values.serviceAccount.name }}
    {{- fail "serviceAccount.name must be set when serviceAccount.create is true" }}
  {{- end }}
{{- end }}
{{- end }}