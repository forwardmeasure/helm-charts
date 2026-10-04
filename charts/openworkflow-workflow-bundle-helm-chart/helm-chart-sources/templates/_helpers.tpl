{{/* The release's resource name. */}}
{{- define "openworkflow-workflow-bundle.name" -}}
{{- printf "%s-workflows" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Labels shared by every resource; the domain label lets tenant provisioning find bundles. */}}
{{- define "openworkflow-workflow-bundle.labels" -}}
app.kubernetes.io/name: openworkflow-workflow-bundle
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
openworkflow.forwardmeasure.com/workflow-bundle: "true"
openworkflow.forwardmeasure.com/domain: {{ .Values.domain | quote }}
{{- end -}}

{{/* Fails the render on settings the publisher can't run without. */}}
{{- define "openworkflow-workflow-bundle.validate" -}}
{{- if not (regexMatch "^[a-z][a-z0-9]*(-[a-z0-9]+)*$" (.Values.domain | default "")) -}}
{{- fail "domain is required: lowercase letters, digits and single hyphens, e.g. fei" -}}
{{- end -}}
{{- if not .Values.definitions -}}
{{- fail "definitions must hold at least one workflow document" -}}
{{- end -}}
{{- range $file, $_ := .Values.definitions -}}
{{- if not (regexMatch "^[^./][^/]*\\.ya?ml$" $file) -}}
{{- fail (printf "definitions key %s must be a *.yaml or *.yml file name" $file) -}}
{{- end -}}
{{- end -}}
{{- if .Values.didMethod -}}
{{- if not (regexMatch "^[a-z0-9]+$" .Values.didMethod) -}}
{{- fail (printf "didMethod %s must be lowercase letters and digits, e.g. fwm" .Values.didMethod) -}}
{{- end -}}
{{- else -}}
{{- range $file, $text := .Values.definitions -}}
{{- if contains "@BUNDLE_DID@" $text -}}
{{- fail (printf "didMethod is required: definition %s uses @BUNDLE_DID@ (set it from the shared platform.identity.didMethod)" $file) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- range $file, $_ := .Values.apiDocuments -}}
{{- if not (regexMatch "^[A-Za-z0-9][A-Za-z0-9._-]*\\.(ya?ml|json)$" $file) -}}
{{- fail (printf "apiDocuments key %s must be a *.yaml, *.yml or *.json file name" $file) -}}
{{- end -}}
{{- end -}}
{{- if and .Values.apiDocuments (not .Values.registry.apiUrl) -}}
{{- fail "registry.apiUrl is required when apiDocuments are given" -}}
{{- end -}}
{{- if not .Values.tenants -}}
{{- fail "tenants must list at least one tenant alias" -}}
{{- end -}}
{{- if not (or .Values.image.digest .Values.image.tag) -}}
{{- fail "image.digest (or, until it is resolved, image.tag) is required" -}}
{{- end -}}
{{- end -}}
