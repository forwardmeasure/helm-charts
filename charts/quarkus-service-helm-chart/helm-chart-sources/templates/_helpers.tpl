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
Container image reference resolver.
digest takes precedence over tag.
Supports jvm and native runtime modes — image config is per-service.
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
Kubernetes Secret name for ESO-materialised secrets.
Convention: <release>-<secretName>
Centralised here so all templates use the same naming pattern.
Usage: include "quarkus-service.k8sSecretName" (dict "root" $ "secretName" "my-secret")
*/}}
{{- define "quarkus-service.k8sSecretName" -}}
{{- printf "%s-%s" .root.Release.Name .secretName -}}
{{- end }}

{{/*
Resolve the effective secret store name.
Prefer per-service override, then chart-level default.
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
Prefer per-service override, then chart-level default.
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
Prefer per-service cloudSqlProxy.secretName override, then fall back to
the service name itself — convention: secrets are named after their service.
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
Resolve whether the liquibase wait init container should be rendered
for a given service.
Resolution order:
  1. Per-service liquibaseWait.enabled — explicit opt-in or opt-out
  2. Chart-level liquibaseWait.enabled — default for all services
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
Resolve the liquibase service internal URL for the wait init container.
Format: http://<serviceName>.<serviceNamespace>.svc.cluster.local
Matches the Knative internal DNS pattern confirmed in the cluster.
Usage: include "quarkus-service.liquibaseServiceUrl" .root
*/}}
{{- define "quarkus-service.liquibaseServiceUrl" -}}
{{- printf "http://%s.%s.svc.cluster.local" .Values.liquibaseWait.serviceName .Values.liquibaseWait.serviceNamespace -}}
{{- end }}

{{/*
Resolve the tenant ID for the liquibase wait init container.
Resolution order:
  1. Per-service liquibaseWait.tenantId — static override
  2. Falls back to reading DATAFABRIC_DEFAULT_TENANT env var at runtime
     (the script uses the env var directly if no static override is set)
Usage: include "quarkus-service.liquibaseWaitTenantId" (dict "service" . "root" $)
Returns static tenant ID string, or empty string to signal env var fallback.
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
digest takes precedence over tag.
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
{{- end }}

{{/*
Resolve the fully qualified Kafka topic name for a topic entry.
Assembles: <kafka.topicPrefix>.<topic.suffix>
Usage: include "quarkus-service.kafkaTopicName" (dict "root" $ "topic" .topic)
*/}}
{{- define "quarkus-service.kafkaTopicName" -}}
{{- $prefix := .root.Values.kafka.topicPrefix | default "com.forwardmeasure" -}}
{{- printf "%s.%s" $prefix .topic.suffix -}}
{{- end }}

{{/*
Resolve the Kafka namespace for KafkaTopic resources.
Prefer chart-level kafka.namespace, default to "kafka".
Usage: include "quarkus-service.kafkaNamespace" $
*/}}
{{- define "quarkus-service.kafkaNamespace" -}}
{{- .Values.kafka.namespace | default "kafka" -}}
{{- end }}

{{/*
Resolve the Strimzi cluster name for KafkaTopic resources.
Prefer chart-level kafka.clusterName, default to "kafka-cluster".
Usage: include "quarkus-service.kafkaClusterName" $
*/}}
{{- define "quarkus-service.kafkaClusterName" -}}
{{- .Values.kafka.clusterName | default "kafka-cluster" -}}
{{- end }}
