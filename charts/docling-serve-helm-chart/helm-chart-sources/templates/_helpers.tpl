{{- define "docling-serve.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- define "docling-serve.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name (include "docling-serve.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- define "docling-serve.selectorLabels" -}}
app.kubernetes.io/name: {{ include "docling-serve.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
{{- define "docling-serve.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name (.Chart.Version | replace "+" "_") }}
{{ include "docling-serve.selectorLabels" . }}
app.kubernetes.io/version: {{ (default .Values.image.tag (index .Values.image .Values.mode).tag) | trimPrefix "v" | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}
{{- define "docling-serve.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "docling-serve.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}
{{- define "docling-serve.libraryName" -}}
{{- $identity := dict "models" (include "docling-serve.modelConfig" .) "script" (.Files.Get "files/model-preparation.py") | toJson | sha256sum -}}
{{- printf "%s-models-%s" (include "docling-serve.fullname" . | trunc 39 | trimSuffix "-") ($identity | trunc 16) -}}
{{- end -}}
{{- define "docling-serve.claimName" -}}
{{- default (printf "%s-cache" (include "docling-serve.fullname" . | trunc 57 | trimSuffix "-")) .Values.persistence.existingClaim -}}
{{- end -}}
{{- define "docling-serve.pvName" -}}
{{- $prefix := printf "%s-%s" .Release.Namespace (include "docling-serve.fullname" .) | trunc 48 | trimSuffix "-" -}}
{{- default (printf "%s-model-cache-pv" $prefix) .Values.persistence.volumeName -}}
{{- end -}}
{{- define "docling-serve.modelSource" -}}
{{- if eq .Values.modelSource "auto" -}}
{{- ternary "pvc" "image" .Values.modelDownload.enabled -}}
{{- else -}}
{{- .Values.modelSource -}}
{{- end -}}
{{- end -}}
{{- define "docling-serve.image" -}}
{{- $spec := index .Values.image .Values.mode -}}
{{- if $spec.digest -}}
{{- printf "%s@%s" $spec.repository $spec.digest -}}
{{- else -}}
{{- printf "%s:%s" $spec.repository (default .Values.image.tag $spec.tag) -}}
{{- end -}}
{{- end -}}
{{- define "docling-serve.preparationImage" -}}
{{- $mode := ternary "cpu" .Values.mode .Values.modelDownload.useCpuImage -}}
{{- $spec := index .Values.modelDownload.image $mode -}}
{{- $base := index .Values.image $mode -}}
{{- $repo := default $base.repository $spec.repository -}}
{{- $tag := default (default .Values.image.tag $base.tag) $spec.tag -}}
{{- $digest := $spec.digest -}}
{{- if and (not $spec.repository) (not $spec.tag) (not $digest) -}}
{{- $digest = $base.digest -}}
{{- end -}}
{{- if $digest -}}
{{- printf "%s@%s" $repo $digest -}}
{{- else -}}
{{- printf "%s:%s" $repo $tag -}}
{{- end -}}
{{- end -}}
{{- define "docling-serve.modelConfig" -}}
{{- $repositories := list -}}
{{- range $token := .Values.modelDownload.ensembleModels -}}
{{- if not (hasKey $.Values.modelDownload.namedModels $token) -}}
{{- fail (printf "No pinned model inventory for ensemble token %s" $token) -}}
{{- end -}}
{{- range $model := index $.Values.modelDownload.namedModels $token -}}
{{- $repositories = append $repositories $model -}}
{{- end -}}
{{- end -}}
{{- /* VLM models to provision: the boot pipeline (when it is a VLM) plus every
       modelDownload.includeVlm entry, deduplicated. includeVlm decouples VLM
       provisioning from the boot pipeline so pipeline=standard can still serve
       on-request VLM from the bundle. */ -}}
{{- $vlmKeys := list -}}
{{- if ne .Values.pipeline "standard" -}}
{{- $vlmKeys = append $vlmKeys .Values.pipeline -}}
{{- end -}}
{{- range $k := .Values.modelDownload.includeVlm -}}
{{- if not (has $k $vlmKeys) -}}
{{- $vlmKeys = append $vlmKeys $k -}}
{{- end -}}
{{- end -}}
{{- range $k := $vlmKeys -}}
{{- if ne (index $.Values.modelDownload.hfRepos $k) (index $.Values.pipelines $k).vlmModelId -}}
{{- fail (printf "The VLM download repository for %s must match pipelines.%s.vlmModelId" $k $k) -}}
{{- end -}}
{{- $required := list "config.json" -}}
{{- if eq $k "vlm-small" -}}
{{- $required = append $required "model.safetensors" -}}
{{- else -}}
{{- $required = append $required "model.safetensors.index.json" -}}
{{- end -}}
{{- $repositories = append $repositories (dict "repo" (index $.Values.modelDownload.hfRepos $k) "revision" (index $.Values.modelDownload.revisions $k) "requiredFiles" $required) -}}
{{- end -}}
{{- if not $repositories -}}
{{- fail "The model inventory must select at least one model" -}}
{{- end -}}
{{- dict "formatVersion" 1 "image" (include "docling-serve.preparationImage" .) "repositories" $repositories | toJson -}}
{{- end -}}
{{- define "docling-serve.bundleId" -}}
{{- include "docling-serve.modelConfig" . | sha256sum -}}
{{- end -}}
{{- define "docling-serve.preparationJobId" -}}
{{- /* A Job Pod template is immutable, including resources, mounts and identity. */ -}}
{{- dict "values" .Values "script" (.Files.Get "files/model-preparation.py") "chartVersion" .Chart.Version | toJson | sha256sum -}}
{{- end -}}
{{- define "docling-serve.artifactsPath" -}}
{{- if eq (include "docling-serve.modelSource" .) "image" -}}
{{- .Values.paths.imageModels -}}
{{- else if .Values.modelDownload.enabled -}}
{{- printf "%s/.bundles/%s" .Values.paths.models (include "docling-serve.bundleId" .) -}}
{{- else -}}
{{- .Values.paths.models -}}
{{- end -}}
{{- end -}}
{{- define "docling-serve.validate" -}}
{{- $source := include "docling-serve.modelSource" . -}}
{{- if and (eq .Values.mode "cpu") (eq .Values.pipeline "vlm-large") -}}
{{- fail "Invalid configuration: cpu mode does not support vlm-large pipeline" -}}
{{- end -}}
{{- if and (eq $source "image") .Values.modelDownload.enabled -}}
{{- fail "modelSource=image cannot enable modelDownload; use auto or pvc" -}}
{{- end -}}
{{- if and (eq $source "image") (ne .Values.pipeline "standard") -}}
{{- fail "VLM profiles require modelSource=pvc with prepared models or modelDownload.enabled=true" -}}
{{- end -}}
{{- range $k := .Values.modelDownload.includeVlm -}}
{{- if not (hasKey $.Values.modelDownload.hfRepos $k) -}}
{{- fail (printf "modelDownload.includeVlm entry %s is not a known VLM key (expected vlm-small or vlm-large)" $k) -}}
{{- end -}}
{{- if and (eq $.Values.mode "cpu") (eq $k "vlm-large") -}}
{{- fail "modelDownload.includeVlm cannot contain vlm-large in cpu mode; it requires GPU" -}}
{{- end -}}
{{- end -}}
{{- if and .Values.modelDownload.includeVlm (eq $source "image") -}}
{{- fail "modelDownload.includeVlm requires a prepared bundle; modelSource=image has no VLM assets" -}}
{{- end -}}
{{- if and (eq $source "pvc") (not .Values.persistence.create) (not .Values.persistence.existingClaim) -}}
{{- fail "PVC model storage requires persistence.create=true or persistence.existingClaim" -}}
{{- end -}}
{{- if and .Values.modelDownload.enabled (eq .Values.persistence.accessMode "ReadOnlyMany") -}}
{{- fail "Model preparation requires writable PVC access; ReadOnlyMany is for already prepared models" -}}
{{- end -}}
{{- if and .Values.modelDownload.enabled (eq .Values.modelDownload.preparation "job") (eq .Values.persistence.accessMode "ReadWriteOncePod") -}}
{{- fail "Job preparation uses two Pods and cannot share a ReadWriteOncePod claim; use init preparation" -}}
{{- end -}}
{{- if and .Values.persistence.bindToPv .Values.persistence.existingClaim -}}
{{- fail "bindToPv cannot be combined with existingClaim" -}}
{{- end -}}
{{- if and .Values.persistence.bindToPv (not .Values.persistence.create) -}}
{{- fail "bindToPv requires persistence.create=true" -}}
{{- end -}}
{{- if .Values.persistence.bindToPv -}}
{{- if ne (len .Values.persistence.volumeSource) 1 -}}
{{- fail "A static PV requires exactly one persistence.volumeSource (csi, nfs, local or hostPath)" -}}
{{- end -}}
{{- if and (hasKey .Values.persistence.volumeSource "local") (not .Values.persistence.nodeAffinity) -}}
{{- fail "A local static PV requires persistence.nodeAffinity" -}}
{{- end -}}
{{- end -}}
{{- if and .Values.auth.enabled (not .Values.auth.existingSecret) -}}
{{- fail "auth.enabled requires auth.existingSecret supplied by platform-secrets" -}}
{{- end -}}
{{- if and (ne .Values.engine.kind "local") (not .Values.engine.redisSecret.name) -}}
{{- fail "rq/ray requires engine.redisSecret.name and separately deployed workers/backend" -}}
{{- end -}}
{{- if and (eq .Values.engine.kind "ray") (not (get .Values.env "DOCLING_SERVE_ENG_RAY_ADDRESS")) (not (hasKey .Values.envSecretRefs "DOCLING_SERVE_ENG_RAY_ADDRESS")) -}}
{{- fail "ray requires env.DOCLING_SERVE_ENG_RAY_ADDRESS or its envSecretRefs entry" -}}
{{- end -}}
{{- if and (gt (int .Values.replicaCount) 1) (eq .Values.engine.kind "local") -}}
{{- fail "Multiple API replicas require a shared rq/ray task backend; local state cannot route asynchronous results across pods" -}}
{{- end -}}
{{- if and (gt (int .Values.replicaCount) 1) (eq $source "pvc") (ne .Values.persistence.accessMode "ReadWriteMany") -}}
{{- fail "Multiple API replicas with PVC models require ReadWriteMany; use image models or separately scaled workers" -}}
{{- end -}}
{{- if and (eq .Values.strategy.type "RollingUpdate") (eq $source "pvc") (ne .Values.persistence.accessMode "ReadWriteMany") -}}
{{- fail "RollingUpdate with a single-node model PVC can stall attachment; use Recreate or ReadWriteMany" -}}
{{- end -}}
{{- $reserved := list "DOCLING_SERVE_ARTIFACTS_PATH" "HF_HOME" "HF_HUB_CACHE" "DOCLING_SERVE_SCRATCH_PATH" "DOCLING_SERVE_ENG_KIND" "DOCLING_SERVE_API_KEY" "DOCLING_SERVE_ENG_RQ_REDIS_URL" "DOCLING_SERVE_ENG_RAY_REDIS_URL" "DOCLING_SERVE_MAX_FILE_SIZE" "DOCLING_SERVE_MAX_NUM_PAGES" "DOCLING_SERVE_MAX_DOCUMENT_TIMEOUT" "DOCLING_SERVE_MAX_SOURCES_PER_REQUEST" "DOCLING_SERVE_MAX_IMAGES_SCALE" -}}
{{- if or (ne .Values.pipeline "standard") .Values.modelDownload.includeVlm -}}
{{- $reserved = concat $reserved (list "DOCLING_SERVE_DEFAULT_VLM_PRESET" "DOCLING_SERVE_ALLOWED_VLM_PRESETS") -}}
{{- end -}}
{{- range $name, $_ := .Values.env -}}
{{- if has $name $reserved -}}
{{- fail (printf "env.%s is managed by the chart; use its dedicated setting" $name) -}}
{{- end -}}
{{- if hasKey $.Values.envSecretRefs $name -}}
{{- fail (printf "Environment variable %s occurs in both env and envSecretRefs" $name) -}}
{{- end -}}
{{- end -}}
{{- range $name, $_ := .Values.envSecretRefs -}}
{{- if has $name $reserved -}}
{{- fail (printf "envSecretRefs.%s is managed by the chart; use its dedicated setting" $name) -}}
{{- end -}}
{{- if and (eq $.Values.mode "gpu") (hasKey $.Values.gpuEnv $name) -}}
{{- fail (printf "Environment variable %s occurs in both gpuEnv and envSecretRefs" $name) -}}
{{- end -}}
{{- end -}}
{{- range $name, $_ := .Values.gpuEnv -}}
{{- if has $name $reserved -}}
{{- fail (printf "gpuEnv.%s is managed by the chart; use its dedicated setting" $name) -}}
{{- end -}}
{{- end -}}
{{- end -}}
