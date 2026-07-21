{{- define "apicurio-registry-operator.labels" -}}
app: apicurio-registry-operator
app.kubernetes.io/name: apicurio-registry-operator
app.kubernetes.io/component: operator
app.kubernetes.io/instance: apicurio-registry-operator
app.kubernetes.io/part-of: apicurio-registry
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}
