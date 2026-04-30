{{/*
Expand the name of the chart.
*/}}
{{- define "funqy-service.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "funqy-service.fullname" -}}
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
Common labels applied to all resources in this release.
*/}}
{{- define "funqy-service.labels" -}}
helm.sh/chart: {{ include "funqy-service.name" . }}-{{ .Chart.Version }}
app.kubernetes.io/name: {{ include "funqy-service.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Function-level labels — includes function name for per-pod identification.
Usage: include "funqy-service.functionLabels" (dict "function" . "root" $)
*/}}
{{- define "funqy-service.functionLabels" -}}
{{ include "funqy-service.labels" .root }}
app.kubernetes.io/component: {{ .function.name }}
funqy-service/family: {{ .root.Release.Name }}
funqy-service/runtime: {{ .function.runtime | default "jvm" }}
{{- end }}

{{/*
Container image reference resolver.
digest takes precedence over tag.
Supports jvm and native runtime modes — image config is per-function.
Usage: include "funqy-service.imageRef" (dict "image" .image)
*/}}
{{- define "funqy-service.imageRef" -}}
{{- $registry := .image.registry | default "docker.io" -}}
{{- $repo     := .image.repository -}}
{{- $digest   := .image.digest | default "" -}}
{{- if $digest -}}
{{- printf "%s/%s@%s" $registry $repo $digest -}}
{{- else -}}
{{- printf "%s/%s:%s" $registry $repo (.image.tag | default "latest") -}}
{{- end -}}
{{- end }}

{{/*
Kubernetes Secret name for ESO-materialised secrets.
Convention: <release>-<secretName>
Usage: include "funqy-service.k8sSecretName" (dict "root" $ "secretName" "my-secret")
*/}}
{{- define "funqy-service.k8sSecretName" -}}
{{- printf "%s-%s" .root.Release.Name .secretName -}}
{{- end }}

{{/*
Resolve the effective ClusterSecretStore name.
Prefer per-function override, then chart-level default.
Usage: include "funqy-service.secretStoreName" (dict "function" . "root" $)
*/}}
{{- define "funqy-service.secretStoreName" -}}
{{- if and (hasKey .function "externalSecret") (hasKey .function.externalSecret "clusterSecretStore") (.function.externalSecret.clusterSecretStore) }}
{{- .function.externalSecret.clusterSecretStore }}
{{- else }}
{{- .root.Values.externalSecret.clusterSecretStore }}
{{- end }}
{{- end }}

{{/*
Resolve the effective ESO refresh interval.
Prefer per-function override, then chart-level default.
Usage: include "funqy-service.secretRefreshInterval" (dict "function" . "root" $)
*/}}
{{- define "funqy-service.secretRefreshInterval" -}}
{{- if and (hasKey .function "externalSecret") (hasKey .function.externalSecret "refreshInterval") (.function.externalSecret.refreshInterval) }}
{{- .function.externalSecret.refreshInterval }}
{{- else }}
{{- .root.Values.externalSecret.refreshInterval }}
{{- end }}
{{- end }}

{{/*
Validate a function entry has all required fields.
Also validates that cloudSqlProxy.enabled functions include DATA_FABRIC_SVC_DB_NAME
in their secrets list, since the JDBC URL substitution depends on it.
Usage: include "funqy-service.validateFunction" (dict "function" . "root" $)
*/}}
{{- define "funqy-service.validateFunction" -}}
{{- if not .function.name }}
{{- fail "function entry missing required field: name" }}
{{- end }}
{{- if not .function.image }}
{{- fail (printf "function '%s' missing required field: image" .function.name) }}
{{- end }}
{{- if not .function.image.repository }}
{{- fail (printf "function '%s' image missing required field: repository" .function.name) }}
{{- end }}
{{- if not .function.triggers }}
{{- fail (printf "function '%s' missing required field: triggers (at least one Knative Trigger required)" .function.name) }}
{{- end }}
{{- range .function.triggers }}
{{- if not .name }}
{{- fail (printf "function '%s' has a trigger entry missing required field: name" $.function.name) }}
{{- end }}
{{- if not .cloudEventType }}
{{- fail (printf "function '%s' trigger '%s' missing required field: cloudEventType" $.function.name .name) }}
{{- end }}
{{- end }}
{{- if and (hasKey .function "cloudSqlProxy") (.function.cloudSqlProxy.enabled) }}
{{- if not .root.Values.cloudSqlProxy }}
{{- fail (printf "function '%s' has cloudSqlProxy.enabled but chart-level cloudSqlProxy is not configured" .function.name) }}
{{- end }}
{{- $hasDbName := false -}}
{{- range .function.secrets }}
{{- if eq .envVar "DATA_FABRIC_SVC_DB_NAME" }}
{{- $hasDbName = true }}
{{- end }}
{{- end }}
{{- if not $hasDbName }}
{{- fail (printf "function '%s' has cloudSqlProxy.enabled but secrets list does not include DATA_FABRIC_SVC_DB_NAME" .function.name) }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Resolve the Cloud SQL proxy secret name for a function.
Prefer per-function cloudSqlProxy.secretName override, then fall back to
the function name itself — convention: secrets are named after their function.
Usage: include "funqy-service.cloudSqlProxySecretName" (dict "function" . "root" $)
*/}}
{{- define "funqy-service.cloudSqlProxySecretName" -}}
{{- $secretName := "" -}}
{{- if and (hasKey .function "cloudSqlProxy") (hasKey .function.cloudSqlProxy "secretName") (.function.cloudSqlProxy.secretName) -}}
{{- $secretName = .function.cloudSqlProxy.secretName -}}
{{- else -}}
{{- $secretName = .function.name -}}
{{- end -}}
{{- include "funqy-service.k8sSecretName" (dict "root" .root "secretName" $secretName) -}}
{{- end }}

{{/*
Cloud SQL Auth Proxy image reference resolver.
digest takes precedence over tag.
*/}}
{{- define "funqy-service.cloudSqlProxyImageRef" -}}
{{- $registry := .image.registry | default "gcr.io" -}}
{{- $repo     := .image.repository -}}
{{- $digest   := .image.digest | default "" -}}
{{- if $digest -}}
{{- printf "%s/%s@%s" $registry $repo $digest -}}
{{- else -}}
{{- printf "%s/%s:%s" $registry $repo (.image.tag | default "2.14.1") -}}
{{- end -}}
{{- end }}
