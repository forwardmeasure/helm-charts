{{/*
Expand the name of the chart.
*/}}
{{- define "opensearch-wrapper.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Resolve the namespace — allows overriding via namespaceOverride.
*/}}
{{- define "opensearch-wrapper.namespace" -}}
{{- default .Release.Namespace .Values.namespaceOverride }}
{{- end }}

{{/*
Common labels applied to all resources owned by this wrapper chart.
*/}}
{{- define "opensearch-wrapper.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/name: {{ include "opensearch-wrapper.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
{{- end }}

{{/*
Selector labels — used by resources that need to select pods.
*/}}
{{- define "opensearch-wrapper.selectorLabels" -}}
app.kubernetes.io/name: {{ include "opensearch-wrapper.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Resolve the OpenSearch image tag.
Falls back to .Chart.AppVersion if tag is not set in values.
Used by both the StatefulSet (via subchart) and the security init Job.
*/}}
{{- define "opensearch-wrapper.imageTag" -}}
{{- .Values.securityInit.image.tag | default .Chart.AppVersion }}
{{- end }}

{{/*
Full image reference for the security init Job.
*/}}
{{- define "opensearch-wrapper.initImage" -}}
{{- printf "%s:%s" .Values.securityInit.image.repository (include "opensearch-wrapper.imageTag" .) }}
{{- end }}

{{/*
Name of the security init ConfigMap holding the bootstrap script.
*/}}
{{- define "opensearch-wrapper.initScriptConfigMap" -}}
{{- printf "%s-security-init-script" (include "opensearch-wrapper.name" .) }}
{{- end }}

{{/*
Name of the security init Job.
*/}}
{{- define "opensearch-wrapper.initJobName" -}}
{{- printf "%s-security-init" (include "opensearch-wrapper.name" .) }}
{{- end }}

{{/*
Name of the ExternalSecret.
*/}}
{{- define "opensearch-wrapper.externalSecretName" -}}
{{- printf "%s-admin-credentials" (include "opensearch-wrapper.name" .) }}
{{- end }}

{{/*
Validate that certificates.node.dnsName is set.
*/}}
{{- define "opensearch-wrapper.validateNodeDnsName" -}}
{{- if empty .Values.certificates.node.dnsName }}
  {{- fail "certificates.node.dnsName must be set" }}
{{- end }}
{{- end }}

{{/*
Validate that certificates.admin.dnsName is set.
*/}}
{{- define "opensearch-wrapper.validateAdminDnsName" -}}
{{- if empty .Values.certificates.admin.dnsName }}
  {{- fail "certificates.admin.dnsName must be set" }}
{{- end }}
{{- end }}
