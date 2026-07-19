{{- define "model-service.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "model-service.fullname" -}}
{{- if .Values.fullnameOverride }}{{ .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}{{ else }}{{ .Release.Name | trunc 63 | trimSuffix "-" }}{{ end }}
{{- end }}

{{- define "model-service.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/name: {{ include "model-service.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "model-service.selectorLabels" -}}
app.kubernetes.io/name: {{ include "model-service.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "model-service.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}{{ default (include "model-service.fullname" .) .Values.serviceAccount.name }}{{ else }}{{ required "serviceAccount.name is required when serviceAccount.create is false" .Values.serviceAccount.name }}{{ end }}
{{- end }}

{{- define "model-service.image" -}}
{{- $repository := required "image.repository is required" .Values.image.repository -}}
{{- if .Values.image.digest }}{{ printf "%s@%s" $repository .Values.image.digest }}{{ else }}{{ printf "%s:%s" $repository (.Values.image.tag | default .Chart.AppVersion) }}{{ end }}
{{- end }}
