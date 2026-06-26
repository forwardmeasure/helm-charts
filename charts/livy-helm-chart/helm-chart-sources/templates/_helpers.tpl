{{- define "livy.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "livy.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := include "livy.name" . -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "livy.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "livy.labels" -}}
helm.sh/chart: {{ include "livy.chart" . }}
{{ include "livy.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "livy.selectorLabels" -}}
app.kubernetes.io/name: {{ include "livy.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "livy.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "livy.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- required "serviceAccount.name is required when serviceAccount.create=false" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{- define "livy.serverImage" -}}
{{- $tag := default .Chart.AppVersion .Values.image.tag -}}
{{- printf "%s:%s" (required "image.repository is required" .Values.image.repository) $tag -}}
{{- end -}}

{{- define "livy.sparkImage" -}}
{{- if .Values.spark.image.repository -}}
{{- $tag := default (default .Chart.AppVersion .Values.image.tag) .Values.spark.image.tag -}}
{{- printf "%s:%s" .Values.spark.image.repository $tag -}}
{{- else -}}
{{- include "livy.serverImage" . -}}
{{- end -}}
{{- end -}}

{{- define "livy.sparkNamespace" -}}
{{- default .Release.Namespace .Values.spark.namespace -}}
{{- end -}}

{{- define "livy.sparkServiceAccountName" -}}
{{- default (include "livy.serviceAccountName" .) .Values.spark.serviceAccountName -}}
{{- end -}}

{{- define "livy.imagePullSecretsCsv" -}}
{{- $names := list -}}
{{- range .Values.imagePullSecrets -}}
{{- $names = append $names .name -}}
{{- end -}}
{{- join "," $names -}}
{{- end -}}

{{- define "livy.s3CredentialsSecretName" -}}
{{- if and .Values.spark.s3.credentials.create .Values.spark.s3.credentials.existingSecret -}}
{{- fail "Only one of spark.s3.credentials.create or spark.s3.credentials.existingSecret can be set" -}}
{{- end -}}
{{- if .Values.spark.s3.credentials.existingSecret -}}
{{- .Values.spark.s3.credentials.existingSecret -}}
{{- else if .Values.spark.s3.credentials.create -}}
{{- default (printf "%s-s3-credentials" (include "livy.fullname" .)) .Values.spark.s3.credentials.name -}}
{{- end -}}
{{- end -}}
