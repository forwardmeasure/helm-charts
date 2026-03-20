{{/*
Expand the name of the chart.
*/}}
{{- define "kserve-model-serving.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "kserve-model-serving.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name (include "kserve-model-serving.name" .) | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{/*
Common labels applied to all resources owned by this chart.
*/}}
{{- define "kserve-model-serving.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/name: {{ include "kserve-model-serving.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
{{- end }}

{{/*
Resolve whether manifest verification should be skipped for a given model.
Per-model setting takes precedence over chart-level setting.
*/}}
{{- define "kserve-model-serving.skipVerification" -}}
{{- if hasKey .model "modelCache" }}
{{- if hasKey .model.modelCache "skipManifestVerification" }}
{{- .model.modelCache.skipManifestVerification }}
{{- else }}
{{- .Values.modelCache.skipManifestVerification }}
{{- end }}
{{- else }}
{{- .Values.modelCache.skipManifestVerification }}
{{- end }}
{{- end }}

{{/*
Resolve the PVC name for a given model.
Per-model setting takes precedence over chart-level setting.
*/}}
{{- define "kserve-model-serving.pvcName" -}}
{{- if and (hasKey .model "modelCache") (hasKey .model.modelCache "pvcName") }}
{{- .model.modelCache.pvcName }}
{{- else }}
{{- .Values.modelCache.pvcName }}
{{- end }}
{{- end }}

{{/*
Resolve the ServiceAccount name for a given model.
Per-model setting takes precedence over chart-level setting.
*/}}
{{- define "kserve-model-serving.serviceAccountName" -}}
{{- if and (hasKey .model "modelCache") (hasKey .model.modelCache "serviceAccountName") }}
{{- .model.modelCache.serviceAccountName }}
{{- else }}
{{- .Values.modelCache.serviceAccountName }}
{{- end }}
{{- end }}

{{/*
Resolve image reference from an image block — prefers digest over tag.
Accepts a dict with keys: registry, repository, tag, digest.
Supports both legacy format (repository: registry/repo) and
explicit format (registry: ..., repository: repo).
*/}}
{{- define "kserve-model-serving.imageRef" -}}
{{- $registry := .registry | default "" -}}
{{- $repository := .repository -}}
{{- $digest := .digest | default "" -}}
{{- $tag := .tag | default "latest" -}}
{{- if $digest }}
{{- if $registry }}
{{- printf "%s/%s@%s" $registry $repository $digest }}
{{- else }}
{{- printf "%s@%s" $repository $digest }}
{{- end }}
{{- else }}
{{- if $registry }}
{{- printf "%s/%s:%s" $registry $repository $tag }}
{{- else }}
{{- printf "%s:%s" $repository $tag }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Resolve the model download image for a given model.
Per-model image takes precedence over chart-level image.
Supports registry, repository, tag, and digest fields.
*/}}
{{- define "kserve-model-serving.downloadImage" -}}
{{- $imageBlock := dict -}}
{{- if and (hasKey .model "modelDownload") (hasKey .model.modelDownload "image") }}
{{- $imageBlock = .model.modelDownload.image }}
{{- else }}
{{- $imageBlock = .Values.modelDownload.image }}
{{- end }}
{{- include "kserve-model-serving.imageRef" $imageBlock }}
{{- end }}

{{/*
Validate that a model entry has required fields.
*/}}
{{- define "kserve-model-serving.validateModel" -}}
{{- if empty .model.name }}
  {{- fail "model.name must be set for every entry in the models list" }}
{{- end }}
{{- if empty .model.runtime }}
  {{- fail (printf "model.runtime must be set for model %s" .model.name) }}
{{- end }}
{{- if empty .model.huggingFaceRepo }}
  {{- fail (printf "model.huggingFaceRepo must be set for model %s" .model.name) }}
{{- end }}
{{- end }}
