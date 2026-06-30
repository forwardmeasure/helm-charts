{{/*
Expand the name of the chart.
*/}}
{{- define "quarkus-service.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "quarkus-service.fullname" -}}
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
{{- define "quarkus-service.cloudSqlProxyNativeSidecar" -}}
{{- $svc := .service -}}
{{- $root := .root -}}
{{- $proxy := $root.Values.cloudSqlProxy }}
- name: cloud-sql-proxy
  image: {{ include "quarkus-service.cloudSqlProxyImageRef" $proxy }}
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
          name: {{ include "quarkus-service.cloudSqlProxySecretName" (dict "service" $svc "root" $root) }}
          key: db-cloud-sql-instance
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
{{- define "quarkus-service.labels" -}}
helm.sh/chart: {{ include "quarkus-service.name" . }}-{{ .Chart.Version }}
app.kubernetes.io/name: {{ include "quarkus-service.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Service-level labels — includes service name for per-pod identification.
*/}}
{{- define "quarkus-service.serviceLabels" -}}
{{ include "quarkus-service.labels" .root }}
app.kubernetes.io/component: {{ .service.name }}
quarkus-service/family: {{ .root.Release.Name }}
quarkus-service/runtime: {{ .service.runtime | default "jvm" }}
{{- end }}

{{/*
Merged pod annotations.
Service-level podAnnotations override chart-level podAnnotations for matching
keys. This avoids rendering duplicate YAML keys when a service needs to refine
global pod annotations.
*/}}
{{- define "quarkus-service.podAnnotations" -}}
{{- $rootAnnotations := .root.Values.podAnnotations | default (dict) -}}
{{- $serviceAnnotations := .service.podAnnotations | default (dict) -}}
{{- $annotations := mergeOverwrite (deepCopy $rootAnnotations) $serviceAnnotations -}}
{{- if $annotations -}}
{{- toYaml $annotations -}}
{{- end -}}
{{- end }}

{{/*
Container image reference resolver.
digest takes precedence over tag.
*/}}
{{- define "quarkus-service.imageRef" -}}
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
Kubernetes Secret name for release-level (shared) ESO-materialised secrets.
Convention: <release>-<secretName>
Usage: include "quarkus-service.k8sSecretName" (dict "root" $ "secretName" "my-secret")
*/}}
{{- define "quarkus-service.k8sSecretName" -}}
{{- printf "%s-%s" .root.Release.Name .secretName -}}
{{- end }}

{{/*
Kubernetes Secret name for per-service ESO-materialised secrets.
Convention: <release>-<serviceName>-<secretName>
Usage: include "quarkus-service.k8sPerServiceSecretName" (dict "root" $ "serviceName" "my-service" "secretName" "my-secret")
*/}}
{{- define "quarkus-service.k8sPerServiceSecretName" -}}
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

Usage: include "quarkus-service.resolveSecretName" (dict "root" $ "service" $svc "secretEntry" .)
*/}}
{{- define "quarkus-service.resolveSecretName" -}}
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
{{- include "quarkus-service.k8sSecretName" (dict "root" .root "secretName" .secretEntry.secretName) -}}
{{- else -}}
{{- include "quarkus-service.k8sPerServiceSecretName" (dict "root" .root "serviceName" .service.name "secretName" .secretEntry.secretName) -}}
{{- end -}}
{{- end -}}
{{- end }}

{{/*
Resolve the effective secret store name.
*/}}
{{- define "quarkus-service.secretStoreName" -}}
{{- if and (hasKey .service "externalSecret") (hasKey .service.externalSecret "clusterSecretStore") (.service.externalSecret.clusterSecretStore) }}
{{- .service.externalSecret.clusterSecretStore }}
{{- else }}
{{- .root.Values.externalSecret.clusterSecretStore }}
{{- end }}
{{- end }}

{{/*
Resolve the effective ESO refresh interval.
*/}}
{{- define "quarkus-service.secretRefreshInterval" -}}
{{- if and (hasKey .service "externalSecret") (hasKey .service.externalSecret "refreshInterval") (.service.externalSecret.refreshInterval) }}
{{- .service.externalSecret.refreshInterval }}
{{- else }}
{{- .root.Values.externalSecret.refreshInterval }}
{{- end }}
{{- end }}

{{/*
Resolve the Cloud SQL proxy secret name for a service.
Usage: include "quarkus-service.cloudSqlProxySecretName" (dict "service" . "root" $)
*/}}
{{- define "quarkus-service.cloudSqlProxySecretName" -}}
{{- $secretName := "" -}}
{{- if and (hasKey .service "cloudSqlProxy") (hasKey .service.cloudSqlProxy "secretName") (.service.cloudSqlProxy.secretName) -}}
{{- $secretName = .service.cloudSqlProxy.secretName -}}
{{- else -}}
{{- $secretName = .service.name -}}
{{- end -}}
{{- include "quarkus-service.k8sSecretName" (dict "root" .root "secretName" $secretName) -}}
{{- end }}

{{/*
Resolve whether the liquibase wait init container should be rendered.
Usage: include "quarkus-service.liquibaseWaitEnabled" (dict "service" . "root" $)
Returns "true" or "false" as a string.
*/}}
{{- define "quarkus-service.liquibaseWaitEnabled" -}}
{{- if and (hasKey .service "liquibaseWait") (hasKey .service.liquibaseWait "enabled") -}}
{{- .service.liquibaseWait.enabled | toString -}}
{{- else -}}
{{- .root.Values.liquibaseWait.enabled | toString -}}
{{- end -}}
{{- end }}

{{/*
Resolve the liquibase service internal URL.
Usage: include "quarkus-service.liquibaseServiceUrl" .root
*/}}
{{- define "quarkus-service.liquibaseServiceUrl" -}}
{{- printf "http://%s.%s.svc.cluster.local" .Values.liquibaseWait.serviceName .Values.liquibaseWait.serviceNamespace -}}
{{- end }}

{{/*
Resolve the tenant ID for the liquibase wait init container.
*/}}
{{- define "quarkus-service.liquibaseWaitTenantId" -}}
{{- if and (hasKey .service "liquibaseWait") (hasKey .service.liquibaseWait "tenantId") (.service.liquibaseWait.tenantId) -}}
{{- .service.liquibaseWait.tenantId -}}
{{- else -}}
{{- "" -}}
{{- end -}}
{{- end }}

{{/*
Cloud SQL Auth Proxy image reference resolver.
*/}}
{{- define "quarkus-service.cloudSqlProxyImageRef" -}}
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
Validate a service entry has all required fields.
*/}}
{{- define "quarkus-service.validateService" -}}
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
{{- if not .root.Values.liquibaseWait }}
{{- fail "chart-level liquibaseWait is not configured" }}
{{- end }}
{{- if hasKey .service "keda" }}
{{- fail (printf "service '%s' uses deprecated top-level keda; use scaling.autoscaler: keda with scaling.triggers instead" .service.name) }}
{{- end }}
{{- $deploymentMode := .service.deploymentMode | default "knative" }}
{{- $scaling := .service.scaling | default (dict) }}
{{- if not (or (eq $deploymentMode "knative") (eq $deploymentMode "deployment") (eq $deploymentMode "scaledJob")) }}
{{- fail (printf "service '%s' has invalid deploymentMode '%s'; expected one of: knative, deployment, scaledJob" .service.name $deploymentMode) }}
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
Usage: include "quarkus-service.kafkaTopicName" (dict "root" $ "topic" .topic)
*/}}
{{- define "quarkus-service.kafkaTopicName" -}}
{{- $prefix := .root.Values.kafka.topicPrefix | default "com.forwardmeasure" -}}
{{- printf "%s.%s" $prefix .topic.suffix -}}
{{- end }}

{{/*
Resolve the Kafka namespace for KafkaTopic resources.
*/}}
{{- define "quarkus-service.kafkaNamespace" -}}
{{- .Values.kafka.namespace | default "kafka" -}}
{{- end }}

{{/*
Resolve the Strimzi cluster name for KafkaTopic resources.
*/}}
{{- define "quarkus-service.kafkaClusterName" -}}
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
Usage: include "quarkus-service.initContainers" (dict "service" . "root" $)
*/}}
{{- define "quarkus-service.initContainers" -}}
{{- $svc := .service -}}
{{- $root := .root -}}
{{- $liquibaseEnabled := include "quarkus-service.liquibaseWaitEnabled" (dict "service" $svc "root" $root) -}}
{{- $hasCustomInit := and $svc.initContainers (gt (len $svc.initContainers) 0) -}}
{{- $cloudSqlProxyAsNativeSidecar := and (eq ($svc.deploymentMode | default "knative") "scaledJob") $svc.cloudSqlProxy $svc.cloudSqlProxy.enabled -}}
{{- if or (eq $liquibaseEnabled "true") $hasCustomInit $cloudSqlProxyAsNativeSidecar }}
initContainers:
  {{- if $cloudSqlProxyAsNativeSidecar }}
  {{- include "quarkus-service.cloudSqlProxyNativeSidecar" (dict "service" $svc "root" $root) | nindent 2 }}
  {{- end }}
  {{- if eq $liquibaseEnabled "true" }}
  {{- $lw := $root.Values.liquibaseWait }}
  - name: wait-for-liquibase
    image: {{ $lw.image | default "curlimages/curl:latest" }}
    imagePullPolicy: {{ $lw.imagePullPolicy | default "IfNotPresent" }}
    env:
      - name: LIQUIBASE_SERVICE_URL
        value: {{ include "quarkus-service.liquibaseServiceUrl" $root | quote }}
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
    {{- with .env }}
    env:
      {{- range $key, $val := . }}
      - name: {{ $key }}
        value: {{ $val | quote }}
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
Main application container.
Usage: include "quarkus-service.mainContainer" (dict "service" . "root" $)
*/}}
{{- define "quarkus-service.mainContainer" -}}
{{- $svc := .service -}}
{{- $root := .root -}}
{{- $probes := $svc.probes | default (dict) -}}
- name: {{ $svc.name }}
  image: {{ include "quarkus-service.imageRef" (dict "image" $svc.image) }}
  imagePullPolicy: {{ $svc.image.pullPolicy | default "IfNotPresent" }}
  ports:
    - name: http1
      containerPort: {{ $svc.port | default 8080 }}
      protocol: TCP
  env:
    - name: QUARKUS_RUNTIME_MODE
      value: {{ $svc.runtime | default "jvm" | quote }}
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
          name: {{ include "quarkus-service.resolveSecretName" (dict "root" $root "service" $svc "secretEntry" .) }}
          key: {{ .secretKey }}
    {{- end }}
    {{- end }}
    {{- if and $svc.cloudSqlProxy $svc.cloudSqlProxy.enabled }}
    - name: QUARKUS_DATASOURCE_JDBC_URL
      value: "jdbc:postgresql://localhost:5432/$(DATA_FABRIC_SVC_DB_NAME)"
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
  livenessProbe:
    httpGet:
      path: {{ $probes.liveness | default "/q/health/live" }}
      port: {{ $svc.port | default 8080 }}
    initialDelaySeconds: {{ $probes.initialDelaySeconds | default 30 }}
    periodSeconds: {{ $probes.periodSeconds | default 10 }}
    timeoutSeconds: {{ $probes.timeoutSeconds | default 5 }}
    failureThreshold: {{ $probes.failureThreshold | default 3 }}
  readinessProbe:
    httpGet:
      path: {{ $probes.readiness | default "/q/health/ready" }}
      port: {{ $svc.port | default 8080 }}
    initialDelaySeconds: {{ $probes.initialDelaySeconds | default 10 }}
    periodSeconds: {{ $probes.periodSeconds | default 5 }}
    timeoutSeconds: {{ $probes.timeoutSeconds | default 3 }}
    failureThreshold: {{ $probes.failureThreshold | default 3 }}
  startupProbe:
    httpGet:
      path: {{ $probes.startup | default "/q/health/started" }}
      port: {{ $svc.port | default 8080 }}
    initialDelaySeconds: {{ $probes.initialDelaySeconds | default 10 }}
    periodSeconds: {{ $probes.periodSeconds | default 5 }}
    failureThreshold: {{ $probes.startupFailureThreshold | default 30 }}
{{- end }}

{{/*
Cloud SQL Auth Proxy sidecar container.
Renders nothing if cloudSqlProxy is not enabled for the service.
Usage: include "quarkus-service.cloudSqlProxySidecar" (dict "service" . "root" $)
*/}}
{{- define "quarkus-service.cloudSqlProxySidecar" -}}
{{- $svc := .service -}}
{{- $root := .root -}}
{{- if and (ne ($svc.deploymentMode | default "knative") "scaledJob") $svc.cloudSqlProxy $svc.cloudSqlProxy.enabled }}
{{- $proxy := $root.Values.cloudSqlProxy }}
- name: cloud-sql-proxy
  image: {{ include "quarkus-service.cloudSqlProxyImageRef" $proxy }}
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
          name: {{ include "quarkus-service.cloudSqlProxySecretName" (dict "service" $svc "root" $root) }}
          key: db-cloud-sql-instance
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
