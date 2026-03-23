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
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "kserve-model-serving.labels" -}}
helm.sh/chart: {{ include "kserve-model-serving.name" . }}-{{ .Chart.Version }}
app.kubernetes.io/name: {{ include "kserve-model-serving.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
ServiceAccount name resolver.
When externalModelCache is true, prefer per-model override, then
modelCache.serviceAccountName, then chart-level serviceAccount.name.
*/}}
{{- define "kserve-model-serving.serviceAccountName" -}}
{{- if and (hasKey .model "modelCache") (hasKey .model.modelCache "serviceAccountName") (.model.modelCache.serviceAccountName) }}
{{- .model.modelCache.serviceAccountName }}
{{- else }}
{{- .Values.modelCache.serviceAccountName }}
{{- end }}
{{- end }}

{{/*
PVC name resolver.
Prefer per-model override, then chart-level modelCache.pvcName.
*/}}
{{- define "kserve-model-serving.pvcName" -}}
{{- if and (hasKey .model "modelCache") (hasKey .model.modelCache "pvcName") (.model.modelCache.pvcName) }}
{{- .model.modelCache.pvcName }}
{{- else }}
{{- .Values.modelCache.pvcName }}
{{- end }}
{{- end }}

{{/*
Skip manifest verification resolver.
Prefer per-model override, then chart-level modelCache.skipManifestVerification.
*/}}
{{- define "kserve-model-serving.skipVerification" -}}
{{- if and (hasKey .model "modelCache") (hasKey .model.modelCache "skipManifestVerification") }}
{{- .model.modelCache.skipManifestVerification | toString }}
{{- else }}
{{- .Values.modelCache.skipManifestVerification | toString }}
{{- end }}
{{- end }}

{{/*
Model download image resolver.
sha takes precedence over digest over tag.
Prefer per-model override for registry/repository/tag/sha/digest,
then chart-level modelDownload.image.
*/}}
{{- define "kserve-model-serving.downloadImage" -}}
{{- $img := .Values.modelDownload.image }}
{{- if and (hasKey .model "modelDownload") (hasKey .model.modelDownload "image") }}
{{- $img = .model.modelDownload.image }}
{{- end }}
{{- $registry := $img.registry | default "docker.io" }}
{{- $repo     := $img.repository }}
{{- $digest   := coalesce $img.sha $img.digest "" }}
{{- if $digest }}
{{- printf "%s/%s@%s" $registry $repo $digest }}
{{- else }}
{{- printf "%s/%s:%s" $registry $repo ($img.tag | default "latest") }}
{{- end }}
{{- end }}

{{/*
Custom container image reference resolver.
sha takes precedence over digest over tag.
Usage: include "kserve-model-serving.customImageRef" .customImage
*/}}
{{- define "kserve-model-serving.customImageRef" -}}
{{- $registry := .registry | default "docker.io" -}}
{{- $repo     := .repository -}}
{{- $digest   := coalesce .sha .digest "" -}}
{{- if $digest -}}
{{- printf "%s/%s@%s" $registry $repo $digest -}}
{{- else -}}
{{- printf "%s/%s:%s" $registry $repo (.tag | default "latest") -}}
{{- end -}}
{{- end }}

{{/*
Validate a model entry has required fields.
*/}}
{{- define "kserve-model-serving.validateModel" -}}
{{- if not .model.name }}
{{- fail "model entry missing required field: name" }}
{{- end }}
{{- if not .model.runtime }}
{{- fail (printf "model '%s' missing required field: runtime" .model.name) }}
{{- end }}
{{- if eq .model.runtime "kserve-custom" }}
{{- if not .model.customImage }}
{{- fail (printf "model '%s' with runtime kserve-custom missing required field: customImage" .model.name) }}
{{- end }}
{{- if not .model.customImage.repository }}
{{- fail (printf "model '%s' customImage missing required field: repository" .model.name) }}
{{- end }}
{{- else }}
{{- if not .model.huggingFaceRepo }}
{{- fail (printf "model '%s' missing required field: huggingFaceRepo" .model.name) }}
{{- end }}
{{- end }}
{{- end }}