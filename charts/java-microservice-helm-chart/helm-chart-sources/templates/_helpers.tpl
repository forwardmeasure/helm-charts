{{/*
Expand the name of the chart.
*/}}
{{- define "java-microservice.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "java-microservice.fullname" -}}
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
Cloud SQL Auth Proxy native sidecar for Kubernetes Jobs.

Regular sidecar containers keep a Job running after the main container exits.
For ScaledJob workloads, render the proxy as a native sidecar initContainer
with restartPolicy: Always. Kubernetes terminates native sidecars when the
regular containers complete, allowing the Job to finish.
*/}}
{{- define "java-microservice.cloudSqlProxyNativeSidecar" -}}
{{- $svc := .service -}}
{{- $root := .root -}}
{{- $proxy := $root.Values.cloudSqlProxy }}
- name: cloud-sql-proxy
  image: {{ include "java-microservice.cloudSqlProxyImageRef" $proxy }}
  imagePullPolicy: {{ $proxy.image.pullPolicy | default "IfNotPresent" }}
  restartPolicy: Always
  args:
    - "--structured-logs"
    - "--port={{ $proxy.port | default 5432 }}"
    {{- if $proxy.privateIp }}
    - "--private-ip"
    {{- end }}
    - "$(DATA_FABRIC_SVC_DB_CLOUD_SQL_INSTANCE)"
  env:
    - name: DATA_FABRIC_SVC_DB_CLOUD_SQL_INSTANCE
      valueFrom:
        secretKeyRef:
          name: {{ include "java-microservice.cloudSqlProxySecretName" (dict "service" $svc "root" $root) }}
          key: {{ $svc.cloudSqlProxy.instanceKey | default "db-cloud-sql-instance" }}
  resources:
    requests:
      cpu: {{ $proxy.resources.requests.cpu | default "100m" | quote }}
      memory: {{ $proxy.resources.requests.memory | default "128Mi" }}
    limits:
      cpu: {{ $proxy.resources.limits.cpu | default "500m" | quote }}
      memory: {{ $proxy.resources.limits.memory | default "256Mi" }}
  securityContext:
    runAsNonRoot: true
    allowPrivilegeEscalation: false
{{- end }}

{{/*
Common labels
*/}}
{{- define "java-microservice.labels" -}}
helm.sh/chart: {{ include "java-microservice.name" . }}-{{ .Chart.Version }}
app.kubernetes.io/name: {{ include "java-microservice.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Service-level labels — includes service name for per-pod identification.
*/}}
{{- define "java-microservice.serviceLabels" -}}
{{ include "java-microservice.labels" .root }}
app.kubernetes.io/component: {{ .service.name }}
java-microservice/family: {{ .root.Release.Name }}
java-microservice/runtime: {{ .service.runtime | default "jvm" }}
java-microservice/framework: {{ .service.framework | default "quarkus" }}
{{- end }}

{{/*
Merged pod annotations.
Service-level podAnnotations override chart-level podAnnotations for matching
keys. This avoids rendering duplicate YAML keys when a service needs to refine
global pod annotations.
*/}}
{{- define "java-microservice.podAnnotations" -}}
{{- $rootAnnotations := .root.Values.podAnnotations | default (dict) -}}
{{- $serviceAnnotations := .service.podAnnotations | default (dict) -}}
{{- $annotations := mergeOverwrite (deepCopy $rootAnnotations) $serviceAnnotations -}}
{{- if $annotations -}}
{{- toYaml $annotations -}}
{{- end -}}
{{- end }}

{{/*
Merged pod-level securityContext.
Chart-level Values.podSecurityContext is the base; service-level
podSecurityContext overrides matching keys. Both default to an empty dict,
which renders nothing at all — matching today's behavior of never setting
spec.template.spec.securityContext.
Usage: include "java-microservice.podSecurityContext" (dict "service" . "root" $)
Returns bare YAML content (no "securityContext:" key) or an empty string.
*/}}
{{- define "java-microservice.podSecurityContext" -}}
{{- $rootCtx := .root.Values.podSecurityContext | default (dict) -}}
{{- $svcCtx := .service.podSecurityContext | default (dict) -}}
{{- $merged := mergeOverwrite (deepCopy $rootCtx) $svcCtx -}}
{{- if $merged -}}
{{- toYaml $merged -}}
{{- end -}}
{{- end }}

{{/*
Merged container-level securityContext. Same override semantics as
java-microservice.podSecurityContext above, applied to the main application
container instead of the pod.
Usage: include "java-microservice.containerSecurityContext" (dict "service" . "root" $)
*/}}
{{- define "java-microservice.containerSecurityContext" -}}
{{- $rootCtx := .root.Values.securityContext | default (dict) -}}
{{- $svcCtx := .service.securityContext | default (dict) -}}
{{- $merged := mergeOverwrite (deepCopy $rootCtx) $svcCtx -}}
{{- if $merged -}}
{{- toYaml $merged -}}
{{- end -}}
{{- end }}

{{/*
Resolve automountServiceAccountToken: service-level setting wins, then
chart-level Values.automountServiceAccountToken, else unset (renders
nothing, leaving Kubernetes' own implicit default of true in effect - same
as today, where this field is never rendered at all).
Usage: include "java-microservice.automountServiceAccountToken" (dict "service" . "root" $)
Returns "true"/"false" or an empty string.
*/}}
{{- define "java-microservice.automountServiceAccountToken" -}}
{{- if hasKey .service "automountServiceAccountToken" -}}
{{- .service.automountServiceAccountToken | toString -}}
{{- else if hasKey .root.Values "automountServiceAccountToken" -}}
{{- .root.Values.automountServiceAccountToken | toString -}}
{{- end -}}
{{- end }}

{{/*
Resolve terminationGracePeriodSeconds: service-level setting wins, then
chart-level Values.terminationGracePeriodSeconds, else unset (renders
nothing, leaving Kubernetes' own implicit default of 30 seconds in effect -
same as today).
Usage: include "java-microservice.terminationGracePeriodSeconds" (dict "service" . "root" $)
Returns the number as a string, or an empty string.
*/}}
{{- define "java-microservice.terminationGracePeriodSeconds" -}}
{{- if hasKey .service "terminationGracePeriodSeconds" -}}
{{- .service.terminationGracePeriodSeconds | toString -}}
{{- else if hasKey .root.Values "terminationGracePeriodSeconds" -}}
{{- .root.Values.terminationGracePeriodSeconds | toString -}}
{{- end -}}
{{- end }}

{{/*
Helm hook annotations for a service's rendered workload resource.

hooks:
  events: ["pre-install", "pre-upgrade"]   # -> helm.sh/hook
  weight: "10"                             # -> helm.sh/hook-weight
  deletePolicy: "before-hook-creation"     # -> helm.sh/hook-delete-policy

Unset by default -> no annotations rendered, matching every existing
consumer. Event names match Helm's own hook-event vocabulary verbatim (see
https://helm.sh/docs/topics/charts_hooks/) so values can be copied straight
from Helm's docs.
Usage: include "java-microservice.hookAnnotations" (dict "service" . "root" $)
Returns bare YAML content (no leading key) or an empty string.
*/}}
{{- define "java-microservice.hookAnnotations" -}}
{{- $hooks := .service.hooks | default (dict) -}}
{{- $lines := list -}}
{{- if $hooks.events -}}
{{- $lines = append $lines (printf "helm.sh/hook: %s" ($hooks.events | join "," | quote)) -}}
{{- end -}}
{{- if $hooks.weight -}}
{{- $lines = append $lines (printf "helm.sh/hook-weight: %s" ($hooks.weight | toString | quote)) -}}
{{- end -}}
{{- if $hooks.deletePolicy -}}
{{- $lines = append $lines (printf "helm.sh/hook-delete-policy: %s" ($hooks.deletePolicy | quote)) -}}
{{- end -}}
{{- if $lines -}}
{{- join "\n" $lines -}}
{{- end -}}
{{- end }}

{{/*
Container image reference resolver.
digest takes precedence over tag.

repository may itself be a Go template referencing {{ .framework }} (and anything
else on the chart's own root context) - e.g.
  repository: "forwardmeasure/entity-intelligence-ingestion-service-{{ .framework }}"
lets one service.framework value (quarkus | spring | micronaut) drive BOTH which
image gets pulled and the framework-conventional probe/datasource-env defaults
(see java-microservice.mainContainer below) from a single place, instead of two
values an author has to keep in sync by hand. A service with no real per-framework
image split just writes a plain, non-templated repository string, same as always -
tpl on a string with no {{ }} in it is a no-op, so this is fully backward compatible.
Usage: include "java-microservice.imageRef" (dict "image" $svc.image "framework" $framework "root" $root)
*/}}
{{- define "java-microservice.imageRef" -}}
{{- $registry := .image.registry | default "docker.io" -}}
{{- $repo     := .image.repository -}}
{{- if .root -}}
{{- $context := mergeOverwrite (deepCopy .root) (dict "framework" (.framework | default "quarkus")) -}}
{{- $repo = tpl $repo $context -}}
{{- end -}}
{{- $digest   := .image.digest | default "" -}}
{{- if $digest -}}
{{- printf "%s/%s@%s" $registry $repo $digest -}}
{{- else -}}
{{- printf "%s/%s:%s" $registry $repo (.image.tag | default "latest") -}}
{{- end -}}
{{- end }}

{{/*
Kubernetes Secret name for release-level (shared) ESO-materialised secrets.
Convention: <release>-<secretName>
Usage: include "java-microservice.k8sSecretName" (dict "root" $ "secretName" "my-secret")
*/}}
{{- define "java-microservice.k8sSecretName" -}}
{{- printf "%s-%s" .root.Release.Name .secretName -}}
{{- end }}

{{/*
Kubernetes ConfigMap name for a release-level literal ConfigMap (Values.configMaps[]).
Convention: <release>-<name> - same shape as k8sSecretName, deliberately, so
a service's configMapVolumeMounts[].configMapName reference reads the same way
as it already does for a shared secretName.
Usage: include "java-microservice.configMapName" (dict "root" $ "name" "my-configmap")
*/}}
{{- define "java-microservice.configMapName" -}}
{{- printf "%s-%s" .root.Release.Name .name -}}
{{- end }}

{{/*
Kubernetes Secret name for per-service ESO-materialised secrets.
Convention: <release>-<serviceName>-<secretName>
Usage: include "java-microservice.k8sPerServiceSecretName" (dict "root" $ "serviceName" "my-service" "secretName" "my-secret")
*/}}
{{- define "java-microservice.k8sPerServiceSecretName" -}}
{{- printf "%s-%s-%s" .root.Release.Name .serviceName .secretName -}}
{{- end }}

{{/*
Resolve the Kubernetes Secret name for a secret reference in a service's
secrets list.

Three resolution modes, checked in order:

1. existingSecretName — if set, the secret already exists in the cluster
   (created by another release, e.g. platform-secrets). Use it directly
   with no name transformation and no ExternalSecret generated.

2. Shared secret — secretName appears in Values.secrets[]. Uses the
   release-level naming convention: <release>-<secretName>.

3. Per-service secret — secretName not in shared block. Uses the
   per-service convention: <release>-<serviceName>-<secretName>.
   An ExternalSecret is generated for this case by external-secret.yaml
   Pass 2.

Usage: include "java-microservice.resolveSecretName" (dict "root" $ "service" $svc "secretEntry" .)
*/}}
{{- define "java-microservice.resolveSecretName" -}}
{{- if .secretEntry.existingSecretName -}}
{{- .secretEntry.existingSecretName -}}
{{- else -}}
{{- $isShared := false -}}
{{- range .root.Values.secrets -}}
  {{- if eq .secretName $.secretEntry.secretName -}}
    {{- $isShared = true -}}
  {{- end -}}
{{- end -}}
{{- if $isShared -}}
{{- include "java-microservice.k8sSecretName" (dict "root" .root "secretName" .secretEntry.secretName) -}}
{{- else -}}
{{- include "java-microservice.k8sPerServiceSecretName" (dict "root" .root "serviceName" .service.name "secretName" .secretEntry.secretName) -}}
{{- end -}}
{{- end -}}
{{- end }}

{{/*
Resolve the effective secret store name.
*/}}
{{- define "java-microservice.secretStoreName" -}}
{{- if and (hasKey .service "externalSecret") (hasKey .service.externalSecret "clusterSecretStore") (.service.externalSecret.clusterSecretStore) }}
{{- .service.externalSecret.clusterSecretStore }}
{{- else }}
{{- .root.Values.externalSecret.clusterSecretStore }}
{{- end }}
{{- end }}

{{/*
Resolve the effective ESO refresh interval.
*/}}
{{- define "java-microservice.secretRefreshInterval" -}}
{{- if and (hasKey .service "externalSecret") (hasKey .service.externalSecret "refreshInterval") (.service.externalSecret.refreshInterval) }}
{{- .service.externalSecret.refreshInterval }}
{{- else }}
{{- .root.Values.externalSecret.refreshInterval }}
{{- end }}
{{- end }}

{{/*
Resolve the Cloud SQL proxy secret name for a service.
An existingSecretName is used verbatim (a pre-existing Secret managed by
another mechanism, no <release>-<secretName> transformation) - the Cloud SQL
proxy sibling of resolveSecretName's own existingSecretName handling for the
generic secrets[] list. Otherwise falls through to the pre-existing
secretName -> database.secretName -> service.name resolution chain, unchanged.
Usage: include "java-microservice.cloudSqlProxySecretName" (dict "service" . "root" $)
*/}}
{{- define "java-microservice.cloudSqlProxySecretName" -}}
{{- if and (hasKey .service "cloudSqlProxy") (hasKey .service.cloudSqlProxy "existingSecretName") (.service.cloudSqlProxy.existingSecretName) -}}
{{- .service.cloudSqlProxy.existingSecretName -}}
{{- else -}}
{{- $secretName := "" -}}
{{- if and (hasKey .service "cloudSqlProxy") (hasKey .service.cloudSqlProxy "secretName") (.service.cloudSqlProxy.secretName) -}}
{{- $secretName = .service.cloudSqlProxy.secretName -}}
{{- else if and (hasKey .service "database") (hasKey .service.database "secretName") (.service.database.secretName) -}}
{{- $secretName = .service.database.secretName -}}
{{- else -}}
{{- $secretName = .service.name -}}
{{- end -}}
{{- include "java-microservice.k8sSecretName" (dict "root" .root "secretName" $secretName) -}}
{{- end -}}
{{- end }}

{{/*
Resolve the Kubernetes secret containing provider-neutral database credentials.
An existingSecretName is used verbatim; otherwise secretName is release-scoped.
*/}}
{{- define "java-microservice.databaseSecretName" -}}
{{- $database := .service.database | default (dict) -}}
{{- if $database.existingSecretName -}}
{{- $database.existingSecretName -}}
{{- else -}}
{{- include "java-microservice.k8sSecretName" (dict "root" .root "secretName" ($database.secretName | default "db")) -}}
{{- end -}}
{{- end }}

{{/*
Resolve whether the liquibase wait init container should be rendered.
Usage: include "java-microservice.liquibaseWaitEnabled" (dict "service" . "root" $)
Returns "true" or "false" as a string.
*/}}
{{- define "java-microservice.liquibaseWaitEnabled" -}}
{{- if and (hasKey .service "liquibaseWait") (hasKey .service.liquibaseWait "enabled") -}}
{{- .service.liquibaseWait.enabled | toString -}}
{{- else -}}
{{- .root.Values.liquibaseWait.enabled | toString -}}
{{- end -}}
{{- end }}

{{/*
Resolve the liquibase service internal URL.
Usage: include "java-microservice.liquibaseServiceUrl" .root
*/}}
{{- define "java-microservice.liquibaseServiceUrl" -}}
{{- printf "http://%s.%s.svc.cluster.local" .Values.liquibaseWait.serviceName .Values.liquibaseWait.serviceNamespace -}}
{{- end }}

{{/*
Resolve the tenant ID for the liquibase wait init container.
*/}}
{{- define "java-microservice.liquibaseWaitTenantId" -}}
{{- if and (hasKey .service "liquibaseWait") (hasKey .service.liquibaseWait "tenantId") (.service.liquibaseWait.tenantId) -}}
{{- .service.liquibaseWait.tenantId -}}
{{- else -}}
{{- "" -}}
{{- end -}}
{{- end }}

{{/*
Cloud SQL Auth Proxy image reference resolver.
*/}}
{{- define "java-microservice.cloudSqlProxyImageRef" -}}
{{- $registry := .image.registry | default "gcr.io" -}}
{{- $repo     := .image.repository -}}
{{- $digest   := .image.digest | default "" -}}
{{- if $digest -}}
{{- printf "%s/%s@%s" $registry $repo $digest -}}
{{- else -}}
{{- printf "%s/%s:%s" $registry $repo (.image.tag | default "2.14.1") -}}
{{- end -}}
{{- end }}

{{/*
Spark executor pod template support.

Spark in Kubernetes client mode lets the driver provide a pod template file for
executor pods. Services opt in with:

spark:
  executorPodTemplate:
    enabled: true

The chart renders the template as a ConfigMap and mounts it into the driver pod.
*/}}
{{- define "java-microservice.sparkExecutorPodTemplateEnabled" -}}
{{- $spark := .service.spark | default (dict) -}}
{{- $template := $spark.executorPodTemplate | default (dict) -}}
{{- if and (hasKey $template "enabled") $template.enabled -}}true{{- else -}}false{{- end -}}
{{- end }}

{{- define "java-microservice.sparkExecutorPodTemplateConfigMapName" -}}
{{- printf "%s-spark-executor-pod-template" .service.name | trunc 253 | trimSuffix "-" -}}
{{- end }}

{{- define "java-microservice.sparkExecutorPodTemplateVolumeName" -}}
spark-executor-pod-template
{{- end }}

{{- define "java-microservice.sparkExecutorPodTemplateMountPath" -}}
{{- $spark := .service.spark | default (dict) -}}
{{- $template := $spark.executorPodTemplate | default (dict) -}}
{{- $template.mountPath | default "/deployments/spark" -}}
{{- end }}

{{- define "java-microservice.sparkExecutorPodTemplateFileName" -}}
{{- $spark := .service.spark | default (dict) -}}
{{- $template := $spark.executorPodTemplate | default (dict) -}}
{{- $template.fileName | default "executor-pod-template.yaml" -}}
{{- end }}

{{- define "java-microservice.sparkExecutorPodTemplateContainerName" -}}
{{- $spark := .service.spark | default (dict) -}}
{{- $template := $spark.executorPodTemplate | default (dict) -}}
{{- $template.executorContainerName | default "spark-kubernetes-executor" -}}
{{- end }}

{{/*
Validate a service entry has all required fields.
*/}}
{{- define "java-microservice.validateService" -}}
{{- if not .service.name }}
{{- fail "service entry missing required field: name" }}
{{- end }}
{{- if not .service.image }}
{{- fail (printf "service '%s' missing required field: image" .service.name) }}
{{- end }}
{{- if not .service.image.repository }}
{{- fail (printf "service '%s' image missing required field: repository" .service.name) }}
{{- end }}
{{- if and (hasKey .service "cloudSqlProxy") (.service.cloudSqlProxy.enabled) }}
{{- if not .root.Values.cloudSqlProxy }}
{{- fail (printf "service '%s' has cloudSqlProxy.enabled but chart-level cloudSqlProxy is not configured" .service.name) }}
{{- end }}
{{- end }}
{{- if and (hasKey .service "database") (.service.database.enabled) }}
{{- if and (hasKey .service.database "secretName") (hasKey .service.database "existingSecretName") .service.database.secretName .service.database.existingSecretName }}
{{- fail (printf "service '%s' database must set only one of secretName or existingSecretName" .service.name) }}
{{- end }}
{{- end }}
{{- if not .root.Values.liquibaseWait }}
{{- fail "chart-level liquibaseWait is not configured" }}
{{- end }}
{{- if hasKey .service "keda" }}
{{- fail (printf "service '%s' uses deprecated top-level keda; use scaling.autoscaler: keda with scaling.triggers instead" .service.name) }}
{{- end }}
{{- $deploymentMode := .service.deploymentMode | default "knative" }}
{{- $scaling := .service.scaling | default (dict) }}
{{- if not (or (eq $deploymentMode "knative") (eq $deploymentMode "deployment") (eq $deploymentMode "scaledJob") (eq $deploymentMode "job")) }}
{{- fail (printf "service '%s' has invalid deploymentMode '%s'; expected one of: knative, deployment, scaledJob, job" .service.name $deploymentMode) }}
{{- end }}
{{- if and (eq $deploymentMode "knative") .service.extraPorts (gt (len .service.extraPorts) 0) }}
{{- fail (printf "service '%s' sets extraPorts but deploymentMode=knative; Knative Serving permits only a single container port, use deploymentMode: deployment or job" .service.name) }}
{{- end }}
{{- if eq $deploymentMode "deployment" }}
{{- $autoscaler := $scaling.autoscaler | default "none" }}
{{- if not (or (eq $autoscaler "none") (eq $autoscaler "hpa") (eq $autoscaler "keda")) }}
{{- fail (printf "service '%s' has invalid scaling.autoscaler '%s'; expected one of: none, hpa, keda" .service.name $autoscaler) }}
{{- end }}
{{- if and (eq $autoscaler "keda") (not $scaling.triggers) }}
{{- fail (printf "service '%s' has scaling.autoscaler=keda but scaling.triggers is empty" .service.name) }}
{{- end }}
{{- if and (eq $autoscaler "hpa") (not (hasKey $scaling "maxReplicas")) }}
{{- fail (printf "service '%s' has scaling.autoscaler=hpa but scaling.maxReplicas is not set" .service.name) }}
{{- end }}
{{- end }}
{{- if eq $deploymentMode "scaledJob" }}
{{- if not $scaling.triggers }}
{{- fail (printf "service '%s' has deploymentMode=scaledJob but scaling.triggers is empty" .service.name) }}
{{- end }}
{{- if and (hasKey $scaling "autoscaler") (ne ($scaling.autoscaler | default "") "") (ne ($scaling.autoscaler | default "") "none") }}
{{- fail (printf "service '%s' has deploymentMode=scaledJob and must not set scaling.autoscaler" .service.name) }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Resolve the fully qualified Kafka topic name.
Usage: include "java-microservice.kafkaTopicName" (dict "root" $ "topic" .topic)
*/}}
{{- define "java-microservice.kafkaTopicName" -}}
{{- $prefix := .root.Values.kafka.topicPrefix | default "com.forwardmeasure" -}}
{{- printf "%s.%s" $prefix .topic.suffix -}}
{{- end }}

{{/*
Resolve the Kafka namespace for KafkaTopic resources.
*/}}
{{- define "java-microservice.kafkaNamespace" -}}
{{- .Values.kafka.namespace | default "kafka" -}}
{{- end }}

{{/*
Resolve the Strimzi cluster name for KafkaTopic resources.
*/}}
{{- define "java-microservice.kafkaClusterName" -}}
{{- .Values.kafka.clusterName | default "kafka-cluster" -}}
{{- end }}

{{/*
============================================================================
Shared pod spec helpers
Used by both knative-service.yaml and deployment.yaml.
============================================================================
*/}}

{{/*
Init containers — liquibase wait and any custom init containers.
Renders the full initContainers: block including the key, or nothing if
no init containers are needed.
Usage: include "java-microservice.initContainers" (dict "service" . "root" $)
*/}}
{{- define "java-microservice.initContainers" -}}
{{- $svc := .service -}}
{{- $root := .root -}}
{{- $liquibaseEnabled := include "java-microservice.liquibaseWaitEnabled" (dict "service" $svc "root" $root) -}}
{{- $hasCustomInit := and $svc.initContainers (gt (len $svc.initContainers) 0) -}}
{{- $isFiniteJobMode := or (eq ($svc.deploymentMode | default "knative") "scaledJob") (eq ($svc.deploymentMode | default "knative") "job") -}}
{{- $cloudSqlProxyAsNativeSidecar := and $isFiniteJobMode $svc.cloudSqlProxy $svc.cloudSqlProxy.enabled -}}
{{- if or (eq $liquibaseEnabled "true") $hasCustomInit $cloudSqlProxyAsNativeSidecar }}
initContainers:
  {{- if $cloudSqlProxyAsNativeSidecar }}
  {{- include "java-microservice.cloudSqlProxyNativeSidecar" (dict "service" $svc "root" $root) | nindent 2 }}
  {{- end }}
  {{- if eq $liquibaseEnabled "true" }}
  {{- $lw := $root.Values.liquibaseWait }}
  - name: wait-for-liquibase
    image: {{ $lw.image | default "curlimages/curl:latest" }}
    imagePullPolicy: {{ $lw.imagePullPolicy | default "IfNotPresent" }}
    env:
      - name: LIQUIBASE_SERVICE_URL
        value: {{ include "java-microservice.liquibaseServiceUrl" $root | quote }}
      - name: MAX_ATTEMPTS
        value: {{ $lw.maxAttempts | default 30 | quote }}
      - name: SLEEP_SECONDS
        value: {{ $lw.sleepSeconds | default 10 | quote }}
    command:
      - /bin/sh
      - -c
      - |
        echo "Waiting for public schema migrations to complete"
        ATTEMPTS=0
        STATUS_URL="${LIQUIBASE_SERVICE_URL}/migration/schemas/public/ready"
        until [ $ATTEMPTS -ge $MAX_ATTEMPTS ]; do
          ATTEMPTS=$((ATTEMPTS + 1))
          echo "Attempt ${ATTEMPTS}/${MAX_ATTEMPTS}: polling ${STATUS_URL}"
          HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "${STATUS_URL}")
          if [ "${HTTP_CODE}" = "200" ]; then
            echo "Public schema migrations complete"
            exit 0
          fi
          echo "Schema not ready (HTTP ${HTTP_CODE}) — waiting ${SLEEP_SECONDS}s"
          sleep ${SLEEP_SECONDS}
        done
        echo "Timed out waiting for public schema migrations after $((MAX_ATTEMPTS * SLEEP_SECONDS))s"
        exit 1
    resources:
      requests:
        cpu: {{ $lw.resources.requests.cpu | default "50m" | quote }}
        memory: {{ $lw.resources.requests.memory | default "32Mi" }}
      limits:
        cpu: {{ $lw.resources.limits.cpu | default "100m" | quote }}
        memory: {{ $lw.resources.limits.memory | default "64Mi" }}
  {{- end }}
  {{- if $hasCustomInit }}
  {{- range $svc.initContainers }}
  {{- if .enabled }}
  - name: {{ .name }}
    image: {{ .image | default "curlimages/curl:latest" }}
    imagePullPolicy: {{ .imagePullPolicy | default "IfNotPresent" }}
    {{- if or .env .secrets }}
    env:
      {{- range $key, $val := .env }}
      - name: {{ $key }}
        value: {{ $val | quote }}
      {{- end }}
      {{- range .secrets }}
      - name: {{ .envVar }}
        valueFrom:
          secretKeyRef:
            name: {{ include "java-microservice.resolveSecretName" (dict "root" $root "service" $svc "secretEntry" .) }}
            key: {{ .secretKey }}
            optional: {{ .optional | default false }}
      {{- end }}
    {{- end }}
    command:
      - /bin/sh
      - -c
      - |
        {{- .script | nindent 8 }}
    resources:
      requests:
        cpu: {{ .resources.requests.cpu | default "50m" | quote }}
        memory: {{ .resources.requests.memory | default "32Mi" }}
      limits:
        cpu: {{ .resources.limits.cpu | default "100m" | quote }}
        memory: {{ .resources.limits.memory | default "64Mi" }}
  {{- end }}
  {{- end }}
  {{- end }}
{{- end }}
{{- end }}

{{/*
Pod volumes shared across workload types.
Usage: include "java-microservice.podVolumes" (dict "service" . "root" $)
*/}}
{{- define "java-microservice.podVolumes" -}}
{{- $secretMounts := .service.secretVolumeMounts | default (list) -}}
{{- $configMapMounts := .service.configMapVolumeMounts | default (list) -}}
{{- $emptyDirMounts := .service.emptyDirVolumeMounts | default (list) -}}
{{- if or (eq (include "java-microservice.sparkExecutorPodTemplateEnabled" (dict "service" .service "root" .root)) "true") (gt (len $secretMounts) 0) (gt (len $configMapMounts) 0) (gt (len $emptyDirMounts) 0) }}
volumes:
  {{- if eq (include "java-microservice.sparkExecutorPodTemplateEnabled" (dict "service" .service "root" .root)) "true" }}
  - name: {{ include "java-microservice.sparkExecutorPodTemplateVolumeName" . }}
    configMap:
      name: {{ include "java-microservice.sparkExecutorPodTemplateConfigMapName" (dict "service" .service "root" .root) }}
  {{- end }}
  {{- range $emptyDirMounts }}
  - name: {{ required "emptyDirVolumeMounts[].name is required" .name }}
    emptyDir:
      {{- with .sizeLimit }}
      sizeLimit: {{ . }}
      {{- end }}
  {{- end }}
  {{- range $secretMounts }}
  - name: {{ required "secretVolumeMounts[].name is required" .name }}
    secret:
      secretName: {{ required "secretVolumeMounts[].secretName is required" .secretName }}
      optional: {{ .optional | default false }}
      {{- with .defaultMode }}
      defaultMode: {{ . }}
      {{- end }}
      {{- with .items }}
      items:
        {{- range . }}
        - key: {{ required "secretVolumeMounts[].items[].key is required" .key }}
          path: {{ required "secretVolumeMounts[].items[].path is required" .path }}
          {{- with .mode }}
          mode: {{ . }}
          {{- end }}
        {{- end }}
      {{- end }}
  {{- end }}
  {{- range $configMapMounts }}
  - name: {{ required "configMapVolumeMounts[].name is required" .name }}
    configMap:
      name: {{ required "configMapVolumeMounts[].configMapName is required" .configMapName }}
      optional: {{ .optional | default false }}
      {{- with .defaultMode }}
      defaultMode: {{ . }}
      {{- end }}
      {{- with .items }}
      items:
        {{- range . }}
        - key: {{ required "configMapVolumeMounts[].items[].key is required" .key }}
          path: {{ required "configMapVolumeMounts[].items[].path is required" .path }}
          {{- with .mode }}
          mode: {{ . }}
          {{- end }}
        {{- end }}
      {{- end }}
  {{- end }}
{{- end }}
{{- end }}

{{/*
Framework-conventional default health-probe paths, keyed by service.framework
(quarkus | spring | micronaut, default quarkus). Always overridable per
service via probes.liveness/.readiness/.startup - this only supplies the
default when a service doesn't set its own. Spring Boot Actuator and
Micronaut both expose a single combined health endpoint by default, not a
dedicated startup path distinct from readiness - startup reuses readiness for
both, which is the common, sane practice (a startup probe just needs a more
lenient threshold, not a different endpoint).
Usage: include "java-microservice.frameworkProbeDefaults" $framework
*/}}
{{- define "java-microservice.frameworkProbeDefaults" -}}
{{- if eq . "spring" }}
liveness: /actuator/health/liveness
readiness: /actuator/health/readiness
startup: /actuator/health/readiness
{{- else if eq . "micronaut" }}
liveness: /health/liveness
readiness: /health/readiness
startup: /health/readiness
{{- else }}
liveness: /q/health/live
readiness: /q/health/ready
startup: /q/health/started
{{- end }}
{{- end }}

{{/*
Framework-conventional datasource credential environment variable names,
keyed by service.framework (quarkus | spring | micronaut, default quarkus).
Only consulted when database.enabled: true - see mainContainer below. Assumes
each framework's single/default datasource (Micronaut's "default"-named
datasource; Quarkus's and Spring's unnamed default) - this chart does not
support wiring multiple named datasources into one service, matching the
scope the original Quarkus-only database.enabled convenience already had.
Usage: include "java-microservice.frameworkDatasourceEnv" $framework
*/}}
{{- define "java-microservice.frameworkDatasourceEnv" -}}
{{- if eq . "spring" }}
username: SPRING_DATASOURCE_USERNAME
password: SPRING_DATASOURCE_PASSWORD
url: SPRING_DATASOURCE_URL
{{- else if eq . "micronaut" }}
username: DATASOURCES_DEFAULT_USERNAME
password: DATASOURCES_DEFAULT_PASSWORD
url: DATASOURCES_DEFAULT_URL
{{- else }}
username: QUARKUS_DATASOURCE_USERNAME
password: QUARKUS_DATASOURCE_PASSWORD
url: QUARKUS_DATASOURCE_JDBC_URL
{{- end }}
{{- end }}

{{/*
Resolve whether the main container gets liveness/readiness/startup probes.
service.probes.enabled wins when set explicitly. Otherwise the default
depends on deploymentMode: true for knative/deployment/scaledJob (identical
to today, where probes always render), false for job - a one-shot batch/v1
Job is supposed to run to completion, not be supervised like a long-running
service, and a failing startupProbe on a slow-starting or non-HTTP Job kills
and restarts it before it ever finishes.
Usage: include "java-microservice.probesEnabled" (dict "service" . "root" $)
Returns "true" or "false" as a string.
*/}}
{{- define "java-microservice.probesEnabled" -}}
{{- $probes := .service.probes | default (dict) -}}
{{- if hasKey $probes "enabled" -}}
{{- $probes.enabled | toString -}}
{{- else if eq (.service.deploymentMode | default "knative") "job" -}}
false
{{- else -}}
true
{{- end -}}
{{- end }}

{{/*
Main application container.
Usage: include "java-microservice.mainContainer" (dict "service" . "root" $)
*/}}
{{- define "java-microservice.mainContainer" -}}
{{- $svc := .service -}}
{{- $root := .root -}}
{{- $probes := $svc.probes | default (dict) -}}
{{- $framework := $svc.framework | default "quarkus" -}}
{{- $probeDefaults := include "java-microservice.frameworkProbeDefaults" $framework | fromYaml -}}
{{- $datasourceEnv := include "java-microservice.frameworkDatasourceEnv" $framework | fromYaml -}}
- name: {{ $svc.name }}
  image: {{ include "java-microservice.imageRef" (dict "image" $svc.image "framework" $framework "root" $root) }}
  imagePullPolicy: {{ $svc.image.pullPolicy | default "IfNotPresent" }}
  {{- with $svc.lifecycle }}
  # Direct pass-through of Kubernetes' own container lifecycle shape (preStop/postStart,
  # exec/httpGet/tcpSocket/sleep) - unset by default, identical to today. Typical use: a
  # `preStop: {exec: {command: [...]}}` grace-period delay before SIGTERM, letting in-flight
  # requests drain and the Service's endpoint list update before the pod actually stops.
  lifecycle:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  ports:
    - name: http1
      containerPort: {{ $svc.port | default 8080 }}
      protocol: TCP
    {{- range $svc.extraPorts }}
    - name: {{ required "extraPorts[].name is required" .name }}
      containerPort: {{ required "extraPorts[].containerPort is required" .containerPort }}
      protocol: {{ .protocol | default "TCP" }}
    {{- end }}
  env:
    {{- if eq $framework "quarkus" }}
    # Read by this image's own entrypoint script to select the jvm vs.
    # GraalVM-native-image launch path - a Quarkus packaging convention, not
    # a real Quarkus config property. No equivalent is wired for Spring/
    # Micronaut yet; add one deliberately (with its own verified env var
    # name) once a native-image entrypoint convention exists for them.
    - name: QUARKUS_RUNTIME_MODE
      value: {{ $svc.runtime | default "jvm" | quote }}
    {{- end }}
    {{- if ne ($svc.deploymentMode | default $root.Values.deploymentMode | default "knative") "knative" }}
    # Pod IP injected via downward API — used by Spark driver so executor
    # pods can connect back via a routable IP address. The pod name (HOSTNAME)
    # is not DNS-resolvable from other pods without a headless Service.
    # Not rendered in Knative mode — Knative admission webhook rejects fieldRef.
    - name: POD_IP
      valueFrom:
        fieldRef:
          fieldPath: status.podIP
    {{- end }}
    {{- if $svc.secrets }}
    {{- range $svc.secrets }}
    - name: {{ .envVar }}
      valueFrom:
        secretKeyRef:
          name: {{ include "java-microservice.resolveSecretName" (dict "root" $root "service" $svc "secretEntry" .) }}
          key: {{ .secretKey }}
          optional: {{ .optional | default false }}
    {{- end }}
    {{- end }}
    {{- $database := $svc.database | default (dict) }}
    {{- if $database.enabled }}
    - name: {{ $datasourceEnv.username }}
      valueFrom:
        secretKeyRef:
          name: {{ include "java-microservice.databaseSecretName" (dict "service" $svc "root" $root) }}
          key: {{ $database.usernameKey | default "db-username" }}
    - name: {{ $datasourceEnv.password }}
      valueFrom:
        secretKeyRef:
          name: {{ include "java-microservice.databaseSecretName" (dict "service" $svc "root" $root) }}
          key: {{ $database.passwordKey | default "db-password" }}
    {{- if and $svc.cloudSqlProxy $svc.cloudSqlProxy.enabled }}
    - name: DATA_FABRIC_SVC_DB_NAME
      valueFrom:
        secretKeyRef:
          name: {{ include "java-microservice.databaseSecretName" (dict "service" $svc "root" $root) }}
          key: {{ $database.databaseNameKey | default "db-name" }}
    - name: {{ $datasourceEnv.url }}
      value: "jdbc:postgresql://localhost:{{ $root.Values.cloudSqlProxy.port | default 5432 }}/$(DATA_FABRIC_SVC_DB_NAME)"
    {{- else }}
    - name: {{ $datasourceEnv.url }}
      valueFrom:
        secretKeyRef:
          name: {{ include "java-microservice.databaseSecretName" (dict "service" $svc "root" $root) }}
          key: {{ $database.jdbcUrlKey | default "db-jdbc-url" }}
    {{- end }}
    {{- end }}
    {{- range $key, $val := $svc.env }}
    - name: {{ $key }}
      value: {{ $val | quote }}
    {{- end }}
  resources:
    requests:
      cpu: {{ $svc.resources.requests.cpu | default "500m" | quote }}
      memory: {{ $svc.resources.requests.memory | default "512Mi" }}
    limits:
      cpu: {{ $svc.resources.limits.cpu | default "2000m" | quote }}
      memory: {{ $svc.resources.limits.memory | default "1Gi" }}
  {{- $secretMounts := $svc.secretVolumeMounts | default (list) }}
  {{- $configMapMounts := $svc.configMapVolumeMounts | default (list) }}
  {{- $emptyDirMounts := $svc.emptyDirVolumeMounts | default (list) }}
  {{- if or (eq (include "java-microservice.sparkExecutorPodTemplateEnabled" (dict "service" $svc "root" $root)) "true") (gt (len $secretMounts) 0) (gt (len $configMapMounts) 0) (gt (len $emptyDirMounts) 0) }}
  volumeMounts:
    {{- if eq (include "java-microservice.sparkExecutorPodTemplateEnabled" (dict "service" $svc "root" $root)) "true" }}
    - name: {{ include "java-microservice.sparkExecutorPodTemplateVolumeName" . }}
      mountPath: {{ include "java-microservice.sparkExecutorPodTemplateMountPath" (dict "service" $svc "root" $root) | quote }}
      readOnly: true
    {{- end }}
    {{- range $emptyDirMounts }}
    - name: {{ required "emptyDirVolumeMounts[].name is required" .name }}
      mountPath: {{ required "emptyDirVolumeMounts[].mountPath is required" .mountPath | quote }}
      readOnly: {{ .readOnly | default false }}
    {{- end }}
    {{- range $secretMounts }}
    - name: {{ required "secretVolumeMounts[].name is required" .name }}
      mountPath: {{ required "secretVolumeMounts[].mountPath is required" .mountPath | quote }}
      readOnly: {{ .readOnly | default true }}
    {{- end }}
    {{- range $configMapMounts }}
    - name: {{ required "configMapVolumeMounts[].name is required" .name }}
      mountPath: {{ required "configMapVolumeMounts[].mountPath is required" .mountPath | quote }}
      readOnly: {{ .readOnly | default true }}
    {{- end }}
  {{- end }}
  {{- $containerSecurityContext := include "java-microservice.containerSecurityContext" (dict "service" $svc "root" $root) }}
  {{- if $containerSecurityContext }}
  securityContext:
    {{- $containerSecurityContext | nindent 4 }}
  {{- end }}
  {{- if eq (include "java-microservice.probesEnabled" (dict "service" $svc "root" $root)) "true" }}
  livenessProbe:
    httpGet:
      path: {{ $probes.liveness | default $probeDefaults.liveness }}
      port: {{ $svc.port | default 8080 }}
    initialDelaySeconds: {{ $probes.initialDelaySeconds | default 30 }}
    periodSeconds: {{ $probes.periodSeconds | default 10 }}
    timeoutSeconds: {{ $probes.timeoutSeconds | default 5 }}
    failureThreshold: {{ $probes.failureThreshold | default 3 }}
  readinessProbe:
    httpGet:
      path: {{ $probes.readiness | default $probeDefaults.readiness }}
      port: {{ $svc.port | default 8080 }}
    initialDelaySeconds: {{ $probes.initialDelaySeconds | default 10 }}
    periodSeconds: {{ $probes.periodSeconds | default 5 }}
    timeoutSeconds: {{ $probes.timeoutSeconds | default 3 }}
    failureThreshold: {{ $probes.failureThreshold | default 3 }}
  startupProbe:
    httpGet:
      path: {{ $probes.startup | default $probeDefaults.startup }}
      port: {{ $svc.port | default 8080 }}
    initialDelaySeconds: {{ $probes.initialDelaySeconds | default 10 }}
    periodSeconds: {{ $probes.periodSeconds | default 5 }}
    failureThreshold: {{ $probes.startupFailureThreshold | default 30 }}
  {{- end }}
{{- end }}

{{/*
Cloud SQL Auth Proxy sidecar container.
Renders nothing if cloudSqlProxy is not enabled for the service.
Usage: include "java-microservice.cloudSqlProxySidecar" (dict "service" . "root" $)
*/}}
{{- define "java-microservice.cloudSqlProxySidecar" -}}
{{- $svc := .service -}}
{{- $root := .root -}}
{{- $deploymentMode := $svc.deploymentMode | default "knative" -}}
{{- if and (ne $deploymentMode "scaledJob") (ne $deploymentMode "job") $svc.cloudSqlProxy $svc.cloudSqlProxy.enabled }}
{{- $proxy := $root.Values.cloudSqlProxy }}
- name: cloud-sql-proxy
  image: {{ include "java-microservice.cloudSqlProxyImageRef" $proxy }}
  imagePullPolicy: {{ $proxy.image.pullPolicy | default "IfNotPresent" }}
  args:
    - "--structured-logs"
    - "--port={{ $proxy.port | default 5432 }}"
    {{- if $proxy.privateIp }}
    - "--private-ip"
    {{- end }}
    - "$(DATA_FABRIC_SVC_DB_CLOUD_SQL_INSTANCE)"
  env:
    - name: DATA_FABRIC_SVC_DB_CLOUD_SQL_INSTANCE
      valueFrom:
        secretKeyRef:
          name: {{ include "java-microservice.cloudSqlProxySecretName" (dict "service" $svc "root" $root) }}
          key: {{ $svc.cloudSqlProxy.instanceKey | default "db-cloud-sql-instance" }}
  resources:
    requests:
      cpu: {{ $proxy.resources.requests.cpu | default "100m" | quote }}
      memory: {{ $proxy.resources.requests.memory | default "128Mi" }}
    limits:
      cpu: {{ $proxy.resources.limits.cpu | default "500m" | quote }}
      memory: {{ $proxy.resources.limits.memory | default "256Mi" }}
  securityContext:
    runAsNonRoot: true
    allowPrivilegeEscalation: false
{{- end }}
{{- end }}

{{/*
Normalize the public name-keyed services map into the internal service list
used by the rendering templates. The map key is the authoritative service
name and is injected into each service configuration as `.name`.

List input remains accepted during the 0.2.x migration window so consumers can
upgrade the chart before converting their values. New configurations should
always use a map because maps support stable environment-specific overlays.
*/}}
{{- define "java-microservice.normalizedServices" -}}
{{- if kindIs "map" .Values.services -}}
  {{- $services := list -}}
  {{- range $name, $configuration := .Values.services -}}
    {{- $service := deepCopy $configuration -}}
    {{- $_ := set $service "name" $name -}}
    {{- $services = append $services $service -}}
  {{- end -}}
  {{- $services | toYaml -}}
{{- else -}}
  {{- .Values.services | default (list) | toYaml -}}
{{- end -}}
{{- end }}
