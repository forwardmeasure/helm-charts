{{/*
Expand the name of the chart.
*/}}
{{- define "triton-serving.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "triton-serving.fullname" -}}
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
Chart label.
*/}}
{{- define "triton-serving.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels.
*/}}
{{- define "triton-serving.labels" -}}
helm.sh/chart: {{ include "triton-serving.chart" . }}
{{ include "triton-serving.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels.
*/}}
{{- define "triton-serving.selectorLabels" -}}
app.kubernetes.io/name: {{ include "triton-serving.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Service account name.
*/}}
{{- define "triton-serving.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "triton-serving.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Resolve image reference from an image block — prefers digest over tag.
Accepts a dict with keys: registry, repository, tag, digest
*/}}
{{- define "triton-serving.imageRef" -}}
{{- $registry := .registry -}}
{{- $repository := .repository -}}
{{- $digest := .digest | default "" -}}
{{- $tag := .tag | default "latest" -}}
{{- if $digest }}
{{- printf "%s/%s@%s" $registry $repository $digest }}
{{- else }}
{{- printf "%s/%s:%s" $registry $repository $tag }}
{{- end }}
{{- end }}

{{/*
Resolve the gitInit image — prefers digest over tag.
*/}}
{{- define "triton-serving.gitInitImage" -}}
{{- include "triton-serving.imageRef" .Values.gitInit.image }}
{{- end }}

{{/*
Resolve image for a model — uses model-level override if set, falls back to group default.
Args: dict with "model" and "root" keys
*/}}
{{- define "triton-serving.modelImage" -}}
{{- $model := .model -}}
{{- $root := .root -}}
{{- $imageBlock := dict
    "registry"   (($model.image).registry   | default $root.Values.image.registry)
    "repository" (($model.image).repository | default $root.Values.image.repository)
    "tag"        (($model.image).tag        | default $root.Values.image.tag)
    "digest"     (($model.image).digest     | default ($root.Values.image.digest | default ""))
-}}
{{- include "triton-serving.imageRef" $imageBlock }}
{{- end }}

{{/*
Resolve resources for a model — uses model-level override if set, falls back to group default.
Args: dict with "model" and "root" keys
*/}}
{{- define "triton-serving.modelResources" -}}
{{- $model := .model -}}
{{- $root := .root -}}
{{- if $model.resources }}
{{- toYaml $model.resources }}
{{- else }}
{{- toYaml $root.Values.resources }}
{{- end }}
{{- end }}

{{/*
Resolve securityContext for a model — uses model-level override if set, falls back to group default.
Args: dict with "model" and "root" keys
*/}}
{{- define "triton-serving.modelSecurityContext" -}}
{{- $model := .model -}}
{{- $root := .root -}}
{{- if $model.securityContext }}
{{- toYaml $model.securityContext }}
{{- else }}
{{- toYaml $root.Values.securityContext }}
{{- end }}
{{- end }}

{{/*
Sanitize a model name for use in Kubernetes resource names.
Replaces underscores and dots with hyphens.
*/}}
{{- define "triton-serving.modelSafeName" -}}
{{- . | replace "_" "-" | replace "." "-" }}
{{- end }}
