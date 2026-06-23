{{/*
Expand the name of the chart.
*/}}
{{- define "geocoding.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "geocoding.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "geocoding.chart" -}}
{{- printf "%s-%s" .Chart.Name (.Chart.Version | replace "+" "_") | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "geocoding.labels" -}}
helm.sh/chart: {{ include "geocoding.chart" . }}
app.kubernetes.io/name: {{ include "geocoding.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "geocoding.selectorLabels" -}}
app.kubernetes.io/name: {{ include "geocoding.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "geocoding.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (printf "%s-service-account" (include "geocoding.fullname" .)) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{- define "geocoding.databaseSecretName" -}}
{{- default (printf "%s-db-credentials" (include "geocoding.fullname" .)) .Values.database.credentialsSecret -}}
{{- end -}}

{{- define "geocoding.postgresServiceName" -}}
{{- printf "%s-postgres" (include "geocoding.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "geocoding.nominatimServiceName" -}}
{{- printf "%s-nominatim" (include "geocoding.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "geocoding.libpostalServiceName" -}}
{{- printf "%s-libpostal" (include "geocoding.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "geocoding.nominatimFlatnodeClaimName" -}}
{{- if .Values.nominatim.flatnode.existingClaim -}}
{{- .Values.nominatim.flatnode.existingClaim -}}
{{- else -}}
{{- printf "%s-flatnode" (include "geocoding.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "geocoding.nominatimImportJobName" -}}
{{- $base := include "geocoding.fullname" . | trunc 38 | trimSuffix "-" -}}
{{- printf "%s-nominatim-import-%d" $base .Release.Revision | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "geocoding.databaseHost" -}}
{{- if .Values.database.host -}}
{{- .Values.database.host -}}
{{- else if .Values.cloudSqlProxy.enabled -}}
{{- .Values.cloudSqlProxy.address -}}
{{- else if .Values.postgres.enabled -}}
{{- include "geocoding.postgresServiceName" . -}}
{{- end -}}
{{- end -}}

{{- define "geocoding.databasePort" -}}
{{- if .Values.cloudSqlProxy.enabled -}}
{{- .Values.cloudSqlProxy.port -}}
{{- else -}}
{{- .Values.database.port -}}
{{- end -}}
{{- end -}}

{{- define "geocoding.cloudSqlProxyContainer" -}}
{{- if .Values.cloudSqlProxy.enabled }}
- name: cloud-sql-proxy
  restartPolicy: Always
  image: "{{ .Values.cloudSqlProxy.image.repository }}:{{ .Values.cloudSqlProxy.image.tag }}"
  imagePullPolicy: {{ .Values.cloudSqlProxy.image.pullPolicy }}
  args:
    {{- if .Values.cloudSqlProxy.privateIp }}
    - "--private-ip"
    {{- end }}
    {{- if .Values.cloudSqlProxy.autoIamAuthn }}
    - "--auto-iam-authn"
    {{- end }}
    {{- if .Values.cloudSqlProxy.structuredLogs }}
    - "--structured-logs"
    {{- end }}
    - "--port={{ .Values.cloudSqlProxy.port }}"
    - "--address={{ .Values.cloudSqlProxy.address }}"
    {{- if .Values.cloudSqlProxy.credentialsSecret }}
    - "--credentials-file={{ .Values.cloudSqlProxy.credentialsMountPath }}/{{ .Values.cloudSqlProxy.credentialsKey }}"
    {{- end }}
    {{- if .Values.cloudSqlProxy.instanceConnectionNameSecret.name }}
    - "$(CLOUD_SQL_INSTANCE_CONNECTION_NAME)"
    {{- else }}
    - {{ .Values.cloudSqlProxy.instanceConnectionName | quote }}
    {{- end }}
  {{- if .Values.cloudSqlProxy.instanceConnectionNameSecret.name }}
  env:
    - name: CLOUD_SQL_INSTANCE_CONNECTION_NAME
      valueFrom:
        secretKeyRef:
          name: {{ .Values.cloudSqlProxy.instanceConnectionNameSecret.name }}
          key: {{ .Values.cloudSqlProxy.instanceConnectionNameSecret.key }}
  {{- end }}
  securityContext:
    runAsNonRoot: true
    allowPrivilegeEscalation: false
  {{- if .Values.cloudSqlProxy.credentialsSecret }}
  volumeMounts:
    - name: cloud-sql-proxy-credentials
      mountPath: {{ .Values.cloudSqlProxy.credentialsMountPath }}
      readOnly: true
  {{- end }}
  resources:
    {{- toYaml .Values.cloudSqlProxy.resources | nindent 4 }}
{{- end }}
{{- end -}}

{{- define "geocoding.cloudSqlProxyVolumes" -}}
{{- if and .Values.cloudSqlProxy.enabled .Values.cloudSqlProxy.credentialsSecret }}
- name: cloud-sql-proxy-credentials
  secret:
    secretName: {{ .Values.cloudSqlProxy.credentialsSecret }}
    items:
      - key: {{ .Values.cloudSqlProxy.credentialsKey }}
        path: {{ .Values.cloudSqlProxy.credentialsKey }}
{{- end }}
{{- end -}}

{{- define "geocoding.databaseDsnScript" -}}
if [ -z "${NOMINATIM_DATABASE_DSN:-}" ]; then
  NOMINATIM_DATABASE_DSN="pgsql:dbname=${PGDATABASE};host=${PGHOST};port=${PGPORT};user=${PGUSER};password=${PGPASSWORD}"
  if [ -n "${PGSSLMODE:-}" ]; then
    NOMINATIM_DATABASE_DSN="${NOMINATIM_DATABASE_DSN};sslmode=${PGSSLMODE}"
  fi
  export NOMINATIM_DATABASE_DSN
fi
export NOMINATIM_DATABASE_WEBUSER="${NOMINATIM_DATABASE_WEBUSER:-{{ .Values.nominatim.database.webUser }}}"
{{- end -}}

{{- define "geocoding.validate" -}}
{{- if and .Values.nominatim.enabled (not .Values.database.createSecret) (not .Values.database.credentialsSecret) -}}
{{- fail "database.credentialsSecret must be set when nominatim.enabled=true and database.createSecret=false" -}}
{{- end -}}
{{- if and .Values.postgres.enabled (not .Values.database.createSecret) (not .Values.database.credentialsSecret) -}}
{{- fail "database.credentialsSecret must be set when postgres.enabled=true and database.createSecret=false" -}}
{{- end -}}
{{- if and .Values.nominatim.enabled .Values.database.createSecret (not .Values.postgres.enabled) (not .Values.database.host) -}}
{{- if not .Values.cloudSqlProxy.enabled -}}
{{- fail "database.host must be set when postgres.enabled=false and database.createSecret=true" -}}
{{- end -}}
{{- end -}}
{{- if and .Values.cloudSqlProxy.enabled .Values.postgres.enabled -}}
{{- fail "cloudSqlProxy.enabled requires postgres.enabled=false" -}}
{{- end -}}
{{- if and .Values.cloudSqlProxy.enabled (not .Values.cloudSqlProxy.instanceConnectionName) (not .Values.cloudSqlProxy.instanceConnectionNameSecret.name) -}}
{{- fail "cloudSqlProxy.instanceConnectionName or cloudSqlProxy.instanceConnectionNameSecret.name must be set when cloudSqlProxy.enabled=true" -}}
{{- end -}}
{{- if and .Values.nominatim.enabled .Values.nominatim.import.enabled (not .Values.nominatim.import.pbfUrl) (not .Values.nominatim.import.pbfPath) -}}
{{- fail "nominatim.import.pbfUrl or nominatim.import.pbfPath must be set when nominatim.import.enabled=true" -}}
{{- end -}}
{{- if and .Values.nominatim.enabled .Values.nominatim.import.enabled (not (has .Values.nominatim.import.mode (list "create" "continue"))) -}}
{{- fail "nominatim.import.mode must be one of: create, continue" -}}
{{- end -}}
{{- if and .Values.nominatim.enabled .Values.nominatim.import.enabled (eq .Values.nominatim.import.mode "continue") (not .Values.nominatim.import.continueStep) -}}
{{- fail "nominatim.import.continueStep must be set when nominatim.import.mode=continue" -}}
{{- end -}}
{{- end -}}
