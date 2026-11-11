{{/* The release's resource name. */}}
{{- define "openworkflow-workflow-bundle.name" -}}
{{- printf "%s-workflows" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Labels shared by every resource; the workflow-namespace label lets tenant provisioning find bundles. */}}
{{- define "openworkflow-workflow-bundle.labels" -}}
app.kubernetes.io/name: openworkflow-workflow-bundle
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
openworkflow.forwardmeasure.com/workflow-bundle: "true"
openworkflow.forwardmeasure.com/workflow-namespace: {{ .Values.workflowNamespace | quote }}
openworkflow.forwardmeasure.com/registry-scope: {{ .Values.scope | quote }}
{{- with .Values.onlyTenant }}
openworkflow.forwardmeasure.com/only-tenant: {{ . | quote }}
{{- end }}
{{- end -}}

{{/* Labels of resources that are not workflows: tenant administration reads labelled ConfigMaps as workflows. */}}
{{- define "openworkflow-workflow-bundle.plainLabels" -}}
app.kubernetes.io/name: openworkflow-workflow-bundle
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{/* The publisher image, by digest when one is set. */}}
{{- define "openworkflow-workflow-bundle.image" -}}
{{- printf "%s%s" .Values.image.repository (ternary (printf "@%s" .Values.image.digest) (printf ":%s" .Values.image.tag) (not (empty .Values.image.digest))) | quote -}}
{{- end -}}

{{/* Whether any definition names a bundle's contracts (its own or another's). */}}
{{- define "openworkflow-workflow-bundle.namesContracts" -}}
{{- $names := false -}}
{{- range $_, $text := .Values.definitions -}}
{{- if regexMatch "@BUNDLE_DID(:[^@\\s]*)?@" $text -}}{{- $names = true -}}{{- end -}}
{{- end -}}
{{- if $names -}}true{{- end -}}
{{- end -}}

{{/* Fails the render on settings the publisher can't run without. */}}
{{- define "openworkflow-workflow-bundle.validate" -}}
{{- if not (regexMatch "^[a-z][a-z0-9]*(-[a-z0-9]+)*$" (.Values.workflowNamespace | default "")) -}}
{{- fail "workflowNamespace is required: lowercase letters, digits and single hyphens, e.g. entity-intelligence" -}}
{{- end -}}
{{- if not (has .Values.scope (list "platform" "tenant")) -}}
{{- fail "scope is required: platform (contracts every tenant shares) or tenant (each target tenant's own); there is no default" -}}
{{- end -}}
{{- if hasKey .Values "apiDocuments" -}}
{{- fail "apiDocuments is renamed contracts (chart 0.3.0): move the files there" -}}
{{- end -}}
{{- if not (or .Values.definitions .Values.contracts) -}}
{{- fail "definitions or contracts must hold at least one file: a release publishes workflow documents, uploads contract files, or both" -}}
{{- end -}}
{{- range $file, $_ := .Values.definitions -}}
{{- if not (regexMatch "^[^./][^/]*\\.ya?ml$" $file) -}}
{{- fail (printf "definitions key %s must be a *.yaml or *.yml file name" $file) -}}
{{- end -}}
{{- end -}}
{{- range $file, $_ := .Values.contracts -}}
{{- if not (regexMatch "^[A-Za-z0-9][A-Za-z0-9._-]*\\.(ya?ml|json|proto)$" $file) -}}
{{- fail (printf "contracts key %s must be a *.yaml, *.yml, *.json or *.proto file name" $file) -}}
{{- end -}}
{{- end -}}
{{- if .Values.definitions -}}
{{- if kindIs "invalid" .Values.contractBundles -}}
{{- fail "contractBundles is required with definitions: map each alias the definitions use (@BUNDLE_DID:<alias>@) to {workflowNamespace, scope}, or set {} when they name no other bundle" -}}
{{- end -}}
{{- if not (kindIs "map" .Values.contractBundles) -}}
{{- fail "contractBundles must be a map of alias to {workflowNamespace, scope}" -}}
{{- end -}}
{{- range $alias, $bundle := .Values.contractBundles -}}
{{- if not (regexMatch "^[A-Za-z0-9][A-Za-z0-9._-]*$" $alias) -}}
{{- fail (printf "contractBundles alias %s must be letters, digits, dots, underscores and hyphens, starting with a letter or digit" $alias) -}}
{{- end -}}
{{- if not (kindIs "map" $bundle) -}}
{{- fail (printf "contractBundles.%s must be {workflowNamespace, scope}" $alias) -}}
{{- end -}}
{{- if not (regexMatch "^[a-z][a-z0-9]*(-[a-z0-9]+)*$" ($bundle.workflowNamespace | default "")) -}}
{{- fail (printf "contractBundles.%s.workflowNamespace is required: the workflow namespace of the bundle the alias names" $alias) -}}
{{- end -}}
{{- if not (has $bundle.scope (list "platform" "tenant")) -}}
{{- fail (printf "contractBundles.%s.scope is required: platform or tenant, the scope of the bundle the alias names" $alias) -}}
{{- end -}}
{{- end -}}
{{- range $file, $text := .Values.definitions -}}
{{- range $token := regexFindAll "@BUNDLE_DID:[^@\\s]*@" $text -1 -}}
{{- $alias := trimSuffix "@" (trimPrefix "@BUNDLE_DID:" $token) -}}
{{- if not (hasKey $.Values.contractBundles $alias) -}}
{{- fail (printf "definition %s uses %s, but contractBundles declares no alias %s" $file $token (quote $alias)) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- if .Values.didMethod -}}
{{- if not (regexMatch "^[a-z0-9]+$" .Values.didMethod) -}}
{{- fail (printf "didMethod %s must be lowercase letters and digits, e.g. fwm" .Values.didMethod) -}}
{{- end -}}
{{- else -}}
{{- range $file, $text := .Values.definitions -}}
{{- if regexMatch "@BUNDLE_DID(:[^@\\s]*)?@" $text -}}
{{- fail (printf "didMethod is required: definition %s names bundle contracts (@BUNDLE_DID@ or @BUNDLE_DID:<alias>@); set it from the shared platform.identity.didMethod" $file) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- if and .Values.contracts (not .Values.registry.apiUrl) -}}
{{- fail "registry.apiUrl is required when contracts are given" -}}
{{- end -}}
{{- if and (include "openworkflow-workflow-bundle.namesContracts" .) (not .Values.registry.apiUrl) -}}
{{- fail "registry.apiUrl is required when definitions name bundle contracts: the publisher pins each reference to its registry version" -}}
{{- end -}}
{{- if and (or .Values.definitions (eq .Values.scope "tenant")) (not .Values.tenants) -}}
{{- fail "tenants must list at least one tenant alias" -}}
{{- end -}}
{{- if not (or .Values.image.digest .Values.image.tag) -}}
{{- fail "image.digest (or, until it is resolved, image.tag) is required" -}}
{{- end -}}
{{- end -}}
