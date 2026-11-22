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

{{- define "geocoding.nominatimPbfCacheClaimName" -}}
{{- if .Values.nominatim.import.pbfCache.existingClaim -}}
{{- .Values.nominatim.import.pbfCache.existingClaim -}}
{{- else -}}
{{- printf "%s-pbf-cache" (include "geocoding.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "geocoding.nominatimImportJobName" -}}
{{- $base := include "geocoding.fullname" . | trunc 38 | trimSuffix "-" -}}
{{- printf "%s-nominatim-import-%d" $base .Release.Revision | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "geocoding.nominatimCloudStorageLocalPath" -}}
{{- if .Values.nominatim.import.cloudStorage.localPath -}}
{{- .Values.nominatim.import.cloudStorage.localPath -}}
{{- else -}}
{{- printf "%s/cloud-storage.osm.pbf" .Values.nominatim.import.pbfCache.mountPath -}}
{{- end -}}
{{- end -}}

{{- define "geocoding.nominatimCloudStorageImage" -}}
{{- $provider := .Values.nominatim.import.cloudStorage.provider -}}
{{- $repository := .Values.nominatim.import.cloudStorage.image.repository -}}
{{- $tag := .Values.nominatim.import.cloudStorage.image.tag -}}
{{- if not $repository -}}
{{- if eq $provider "gcs" -}}
{{- $repository = "gcr.io/google.com/cloudsdktool/google-cloud-cli" -}}
{{- $tag = default "slim" $tag -}}
{{- else if or (eq $provider "s3") (eq $provider "aws") -}}
{{- $repository = "amazon/aws-cli" -}}
{{- $tag = default "2.15.57" $tag -}}
{{- else if eq $provider "azure" -}}
{{- $repository = "mcr.microsoft.com/azure-storage/azcopy" -}}
{{- $tag = default "v10" $tag -}}
{{- end -}}
{{- else if not $tag -}}
{{- $tag = "latest" -}}
{{- end -}}
{{- printf "%s:%s" $repository $tag -}}
{{- end -}}

{{/*
An image reference: repository@digest when a digest is given (what a deployment should run),
otherwise repository:tag. Usage: include "geocoding.image" .Values.nominatim.image
*/}}
{{- define "geocoding.image" -}}
{{- if .digest -}}
{{- printf "%s@%s" .repository .digest -}}
{{- else -}}
{{- printf "%s:%s" .repository .tag -}}
{{- end -}}
{{- end -}}

{{/*
The Nominatim API's wait, run by its wait-for-database init container.

1. The database server is a dependency: pg_isready is tried up to DATABASE_WAIT_ATTEMPTS times, each
   attempt bounded by DATABASE_WAIT_CONNECT_TIMEOUT_SECONDS, with exponential back-off from
   DATABASE_WAIT_INITIAL_BACKOFF_SECONDS, multiplied by DATABASE_WAIT_BACKOFF_MULTIPLIER, up to
   DATABASE_WAIT_MAXIMUM_BACKOFF_SECONDS. When the attempts run out the container fails, naming the
   database and the server's last answer, so the pod shows the failure and Kubernetes restarts it.
2. With WAIT_FOR_IMPORT=true, it then waits for Nominatim's import-completion marker,
   nominatim_properties.database_version, written at the very end of an import. An import is valid
   work in progress (a planet import or restore runs for days), so that wait has no limit; it checks
   every IMPORT_WAIT_POLL_INTERVAL_SECONDS. If the server stops answering during it (psql exit 2),
   step 1's bounded wait applies again.

Every value comes from the chart's values (nominatim.databaseWait, nominatim.api.importWait); the
script holds none. Each state is reported when it changes, with the server's own words. Only psql's
standard output is taken for the marker, so a notice on standard error never passes for one.
*/}}
{{- define "geocoding.waitForImportScript" -}}
set -euo pipefail
: "${PGHOST:?PGHOST is required}"
: "${PGPORT:?PGPORT is required}"
: "${PGDATABASE:?PGDATABASE is required}"
: "${PGUSER:?PGUSER is required}"
: "${DATABASE_WAIT_ATTEMPTS:?DATABASE_WAIT_ATTEMPTS is required}"
: "${DATABASE_WAIT_CONNECT_TIMEOUT_SECONDS:?DATABASE_WAIT_CONNECT_TIMEOUT_SECONDS is required}"
: "${DATABASE_WAIT_INITIAL_BACKOFF_SECONDS:?DATABASE_WAIT_INITIAL_BACKOFF_SECONDS is required}"
: "${DATABASE_WAIT_MAXIMUM_BACKOFF_SECONDS:?DATABASE_WAIT_MAXIMUM_BACKOFF_SECONDS is required}"
: "${DATABASE_WAIT_BACKOFF_MULTIPLIER:?DATABASE_WAIT_BACKOFF_MULTIPLIER is required}"
export PGCONNECT_TIMEOUT="${DATABASE_WAIT_CONNECT_TIMEOUT_SECONDS}"
reported=""
report() {
  if [ "$1" != "${reported}" ]; then
    echo "$1"
    reported="$1"
  fi
}
wait_for_server() {
  local attempt=1 backoff="${DATABASE_WAIT_INITIAL_BACKOFF_SECONDS}" status
  until status="$(pg_isready -t "${DATABASE_WAIT_CONNECT_TIMEOUT_SECONDS}" -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" 2>&1)"; do
    if [ "${attempt}" -ge "${DATABASE_WAIT_ATTEMPTS}" ]; then
      echo "PostgreSQL at ${PGHOST}:${PGPORT} (database ${PGDATABASE}) did not accept connections after ${attempt} attempts: ${status}" >&2
      exit 1
    fi
    report "Waiting for PostgreSQL at ${PGHOST}:${PGPORT} (attempt ${attempt} of ${DATABASE_WAIT_ATTEMPTS}, next in ${backoff} s): ${status}"
    sleep "${backoff}"
    backoff=$(( backoff * DATABASE_WAIT_BACKOFF_MULTIPLIER ))
    if [ "${backoff}" -gt "${DATABASE_WAIT_MAXIMUM_BACKOFF_SECONDS}" ]; then
      backoff="${DATABASE_WAIT_MAXIMUM_BACKOFF_SECONDS}"
    fi
    attempt=$(( attempt + 1 ))
  done
  echo "PostgreSQL at ${PGHOST}:${PGPORT} accepts connections"
}
wait_for_server
if [ "${WAIT_FOR_IMPORT:-false}" != "true" ]; then
  exit 0
fi
: "${IMPORT_WAIT_POLL_INTERVAL_SECONDS:?IMPORT_WAIT_POLL_INTERVAL_SECONDS is required}"
errors="$(mktemp)"
trap 'rm -f "${errors}"' EXIT
while true; do
  code=0
  version="$(psql -X -q -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" -v ON_ERROR_STOP=1 -tA \
      -c "select value from nominatim_properties where property = 'database_version'" 2>"${errors}")" || code=$?
  if [ "${code}" -eq 0 ]; then
    if [ -n "${version}" ]; then
      echo "Nominatim's import into ${PGDATABASE} is complete (database version ${version})"
      exit 0
    fi
    report "Waiting for Nominatim's import into ${PGDATABASE}: it has not recorded its database version yet"
  elif [ "${code}" -eq 2 ]; then
    report "Lost PostgreSQL at ${PGHOST}:${PGPORT} while waiting for Nominatim's import: $(cat "${errors}")"
    wait_for_server
    continue
  else
    report "Waiting for Nominatim's import into ${PGDATABASE}: $(cat "${errors}")"
  fi
  sleep "${IMPORT_WAIT_POLL_INTERVAL_SECONDS}"
done
{{- end -}}

{{/*
The database wait's settings as container environment, from nominatim.databaseWait; used by the
API's wait and by the import Job.
*/}}
{{- define "geocoding.databaseWaitEnv" -}}
{{- with .Values.nominatim.databaseWait }}
- name: DATABASE_WAIT_ATTEMPTS
  value: {{ .attempts | int | toString | quote }}
- name: DATABASE_WAIT_CONNECT_TIMEOUT_SECONDS
  value: {{ .connectTimeoutSeconds | int | toString | quote }}
- name: DATABASE_WAIT_INITIAL_BACKOFF_SECONDS
  value: {{ .initialBackoffSeconds | int | toString | quote }}
- name: DATABASE_WAIT_MAXIMUM_BACKOFF_SECONDS
  value: {{ .maximumBackoffSeconds | int | toString | quote }}
- name: DATABASE_WAIT_BACKOFF_MULTIPLIER
  value: {{ .backoffMultiplier | int | toString | quote }}
{{- end }}
{{- end -}}

{{/*
Fails the render unless every key of a retry block is a whole number of at least 1 and its maximum
back-off is at least its initial one. Usage: include "geocoding.validateRetry" (list "path" dict).
*/}}
{{- define "geocoding.validateRetry" -}}
{{- $path := index . 0 -}}
{{- $retry := index . 1 -}}
{{- range $key := list "attempts" "connectTimeoutSeconds" "initialBackoffSeconds" "maximumBackoffSeconds" "backoffMultiplier" -}}
{{- if not (hasKey $retry $key) -}}
{{- fail (printf "%s.%s is required" $path $key) -}}
{{- end -}}
{{- if not (regexMatch "^[1-9][0-9]*$" (toString (index $retry $key))) -}}
{{- fail (printf "%s.%s must be a whole number of at least 1, not %v" $path $key (index $retry $key)) -}}
{{- end -}}
{{- end -}}
{{- if lt (int $retry.maximumBackoffSeconds) (int $retry.initialBackoffSeconds) -}}
{{- fail (printf "%s.maximumBackoffSeconds must be at least %s.initialBackoffSeconds" $path $path) -}}
{{- end -}}
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
  image: {{ include "geocoding.image" .Values.cloudSqlProxy.image | quote }}
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
{{- include "geocoding.validateRetry" (list "nominatim.databaseWait" .Values.nominatim.databaseWait) -}}
{{- include "geocoding.validateRetry" (list "nominatim.import.download" .Values.nominatim.import.download) -}}
{{- if not (regexMatch "^[1-9][0-9]*$" (toString .Values.nominatim.api.importWait.pollIntervalSeconds)) -}}
{{- fail (printf "nominatim.api.importWait.pollIntervalSeconds must be a whole number of at least 1, not %v" .Values.nominatim.api.importWait.pollIntervalSeconds) -}}
{{- end -}}
{{- range $probe := list "readinessProbe" "livenessProbe" -}}
{{- range $key := list "initialDelaySeconds" "periodSeconds" "timeoutSeconds" "failureThreshold" -}}
{{- if not (regexMatch "^[1-9][0-9]*$" (toString (index (index $.Values.postgres $probe) $key))) -}}
{{- fail (printf "postgres.%s.%s must be a whole number of at least 1" $probe $key) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- if hasKey .Values.nominatim.api "waitTimeoutSeconds" -}}
{{- fail "nominatim.api.waitTimeoutSeconds is not supported: the API waits for the database and for Nominatim's import for as long as they take; remove it" -}}
{{- end -}}
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
{{- if and .Values.nominatim.enabled .Values.nominatim.import.enabled .Values.nominatim.import.pbfUrl -}}
{{- fail "nominatim.import.pbfUrl is not supported; use nominatim.import.pbfUrls instead" -}}
{{- end -}}
{{- if and .Values.nominatim.enabled .Values.nominatim.import.enabled .Values.nominatim.import.pbfPath -}}
{{- fail "nominatim.import.pbfPath is not supported; use nominatim.import.pbfPaths instead" -}}
{{- end -}}
{{- if and .Values.nominatim.enabled .Values.nominatim.import.enabled (not .Values.nominatim.import.pbfUrls) (not .Values.nominatim.import.pbfPaths) (not .Values.nominatim.import.cloudStorage.enabled) -}}
{{- fail "nominatim.import.pbfUrls, nominatim.import.pbfPaths, or nominatim.import.cloudStorage.enabled must be set when nominatim.import.enabled=true" -}}
{{- end -}}
{{- if and .Values.nominatim.enabled .Values.nominatim.import.enabled .Values.nominatim.import.pbfCache.enabled (not .Values.nominatim.import.pbfCache.mountPath) -}}
{{- fail "nominatim.import.pbfCache.mountPath must be set when nominatim.import.pbfCache.enabled=true" -}}
{{- end -}}
{{- if and .Values.nominatim.enabled .Values.nominatim.import.enabled .Values.nominatim.import.cloudStorage.enabled (not .Values.nominatim.import.cloudStorage.uri) -}}
{{- fail "nominatim.import.cloudStorage.uri must be set when nominatim.import.cloudStorage.enabled=true" -}}
{{- end -}}
{{- if and .Values.nominatim.enabled .Values.nominatim.import.enabled .Values.nominatim.import.cloudStorage.enabled (not .Values.nominatim.import.pbfCache.enabled) -}}
{{- fail "nominatim.import.pbfCache.enabled must be true when nominatim.import.cloudStorage.enabled=true" -}}
{{- end -}}
{{- if and .Values.nominatim.enabled .Values.nominatim.import.enabled .Values.nominatim.import.cloudStorage.enabled (not (has .Values.nominatim.import.cloudStorage.provider (list "gcs" "s3" "aws" "azure"))) -}}
{{- fail "nominatim.import.cloudStorage.provider must be one of: gcs, s3, aws, azure" -}}
{{- end -}}
{{- if and .Values.nominatim.enabled .Values.nominatim.import.enabled (not (has .Values.nominatim.import.mode (list "create" "continue"))) -}}
{{- fail "nominatim.import.mode must be one of: create, continue" -}}
{{- end -}}
{{- if and .Values.nominatim.enabled .Values.nominatim.import.enabled (eq .Values.nominatim.import.mode "continue") (not .Values.nominatim.import.continueStep) -}}
{{- fail "nominatim.import.continueStep must be set when nominatim.import.mode=continue" -}}
{{- end -}}
{{- end -}}
