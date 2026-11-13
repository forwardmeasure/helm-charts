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

{{/* The bundle's contracts image, by its digest (validate requires one). */}}
{{- define "openworkflow-workflow-bundle.contractsImage" -}}
{{- printf "%s@%s" .Values.contracts.repository .Values.contracts.digest | quote -}}
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

{{/* The roles the release declares for its contract files (contracts.roles), as a JSON object of
file name to role. */}}
{{- define "openworkflow-workflow-bundle.contractRoles" -}}
{{- toJson (.Values.contracts.roles | default dict) -}}
{{- end -}}

{{/* The contracts image digest of every bundle contractBundles names, as a JSON object of alias to
digest (contractDigests holds each workflow namespace's, the shared platform.contractDigests). Both
Jobs carry it on their pod template, so a named bundle's new contracts image changes the release's
render: the installer upgrades the release, Helm reruns the Job, and the publisher pins the named
bundle's new registry versions. A namespace contractDigests doesn't map, or a digest that isn't a
sha256 one, fails the render: an unknown digest would let the Job keep a stale pin unseen. Empty
when the release names no other bundle. */}}
{{- define "openworkflow-workflow-bundle.contractDigests" -}}
{{- $digests := dict -}}
{{- if kindIs "map" .Values.contractBundles -}}
{{- range $alias, $bundle := .Values.contractBundles -}}
{{- if not (kindIs "map" $bundle) -}}
{{- fail (printf "contractBundles.%s must be {workflowNamespace, scope}" $alias) -}}
{{- end -}}
{{- $namespace := $bundle.workflowNamespace | default "" | toString -}}
{{- if not (hasKey $.Values.contractDigests $namespace) -}}
{{- fail (printf "contractDigests has no digest for workflow namespace %s, which contractBundles.%s names: pass the shared platform.contractDigests whole, and give that namespace's contracts release a pin there" (quote $namespace) $alias) -}}
{{- end -}}
{{- $digest := index $.Values.contractDigests $namespace | default "" | toString -}}
{{- if not (regexMatch "^sha256:[0-9a-f]{64}$" $digest) -}}
{{- fail (printf "contractDigests.%s is required: the contracts image of the bundle contractBundles.%s names, by its sha256 digest (its owner's contracts-image-versions pin, which the install's digest sync fills); there is no fallback" $namespace $alias) -}}
{{- end -}}
{{- $_ := set $digests $alias $digest -}}
{{- end -}}
{{- end -}}
{{- toJson $digests -}}
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
{{- if not (kindIs "map" .Values.contracts) -}}
{{- fail "contracts must be the bundle's contracts image, {repository, digest, roles}" -}}
{{- end -}}
{{- range $key, $_ := .Values.contracts -}}
{{- if not (has $key (list "repository" "digest" "roles")) -}}
{{- fail (printf "contracts.%s: contracts is the bundle's contracts image, {repository, digest, roles}; contract files no longer travel inside the release (chart 0.3.0), the contracts image carries them" $key) -}}
{{- end -}}
{{- end -}}
{{- if hasKey .Values.contracts "roles" -}}
{{- if not (kindIs "map" .Values.contracts.roles) -}}
{{- fail "contracts.roles must map a contract file's name to its role" -}}
{{- end -}}
{{- range $file, $role := .Values.contracts.roles -}}
{{- if not (regexMatch "^[A-Za-z0-9][A-Za-z0-9._-]*\\.(ya?ml|json|proto)$" $file) -}}
{{- fail (printf "contracts.roles key %s must be a contract file's name: *.yaml, *.yml, *.json or *.proto" $file) -}}
{{- end -}}
{{- if not (and (kindIs "string" $role) (le (len $role) 64) (regexMatch "^[a-z][a-z0-9]*(-[a-z0-9]+)*$" $role)) -}}
{{- fail (printf "contracts.roles.%s %v must be lowercase letters and digits in hyphen-separated words, e.g. model-openai-chat-completions" $file $role) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- if .Values.contracts -}}
{{- if not .Values.contracts.repository -}}
{{- fail "contracts.repository is required: the bundle's contracts image, e.g. docker.io/forwardmeasure/<bundle>-contracts" -}}
{{- end -}}
{{- if not (regexMatch "^sha256:[0-9a-f]{64}$" (.Values.contracts.digest | default "")) -}}
{{- fail (printf "contracts.digest is required: the contracts image %s by its sha256 digest (the release's image-versions pin, which the install's digest sync fills); there is no tag fallback" .Values.contracts.repository) -}}
{{- end -}}
{{- end -}}
{{- if not (or .Values.definitions .Values.contracts) -}}
{{- fail "definitions or contracts must be given: a release publishes workflow documents, uploads its contracts image's files, or both" -}}
{{- end -}}
{{- range $file, $_ := .Values.definitions -}}
{{- if not (regexMatch "^[^./][^/]*\\.ya?ml$" $file) -}}
{{- fail (printf "definitions key %s must be a *.yaml or *.yml file name" $file) -}}
{{- end -}}
{{- end -}}
{{- if and .Values.contracts (not .Values.didMethod) -}}
{{- fail "didMethod is required when contracts are given: every uploaded version records its bundle's DID; set it from the shared platform.identity.didMethod" -}}
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
{{- if not (and (kindIs "map" .Values.contractDigests) .Values.contractDigests) -}}
{{- fail "contractDigests is required: every workflow namespace's contracts image digest, the shared platform.contractDigests passed whole; there is no default" -}}
{{- end -}}
{{- $_ := include "openworkflow-workflow-bundle.contractDigests" . -}}
{{- end -}}
