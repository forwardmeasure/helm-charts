{{/*
Return the base name of the chart (shared between OpenSearch and Dashboards)
*/}}
{{- define "opensearch.name" -}}
opensearch
{{- end -}}

{{/*
Return the full name of the main OpenSearch deployment
*/}}
{{- define "opensearch.fullname" -}}
{{ printf "%s-%s" .Release.Name (include "opensearch.name" .) }}
{{- end -}}

{{/*
Return the name used for OpenSearch Dashboards
*/}}
{{- define "opensearch.dashboards.name" -}}
opensearch-dashboards
{{- end -}}

{{/*
Return the full name for the Dashboards deployment
*/}}
{{- define "opensearch.dashboards.fullname" -}}
{{ printf "%s-%s" .Release.Name "dashboards" }}
{{- end -}}
