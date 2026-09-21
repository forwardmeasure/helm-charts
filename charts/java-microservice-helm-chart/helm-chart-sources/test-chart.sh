#!/usr/bin/env bash
set -euo pipefail

chart_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
map_render="$(mktemp)"
neutral_render="$(mktemp)"
legacy_render="$(mktemp)"
gaps_render="$(mktemp)"
trap 'rm -f "${map_render}" "${neutral_render}" "${legacy_render}" "${gaps_render}"' EXIT

helm lint "${chart_dir}"

helm template map-test "${chart_dir}" \
  --namespace test \
  -f "${chart_dir}/test-values-map-base.yaml" \
  -f "${chart_dir}/test-values-map-gcp.yaml" > "${map_render}"

helm template neutral-test "${chart_dir}" \
  --namespace test \
  -f "${chart_dir}/test-values-map-base.yaml" > "${neutral_render}"

grep -q 'name: evidence-api' "${map_render}"
grep -q 'image: docker.io/example/evidence-api:test' "${map_render}"
grep -A2 -q '^  strategy:$' "${map_render}"
grep -q 'type: Recreate' "${map_render}"
grep -q 'name: BASE_SETTING' "${map_render}"
grep -q 'value: "retained"' "${map_render}"
grep -q 'name: GCP_PROJECT_ID' "${map_render}"
grep -q 'value: "test-project"' "${map_render}"
grep -q 'name: cloud-sql-proxy' "${map_render}"
grep -q 'key: db-cloud-sql-instance' "${map_render}"
grep -q 'key: db-name' "${map_render}"
grep -q 'value: "jdbc:postgresql://localhost:5432/$(DATA_FABRIC_SVC_DB_NAME)"' "${map_render}"

grep -q 'name: QUARKUS_DATASOURCE_USERNAME' "${neutral_render}"
grep -q 'name: QUARKUS_DATASOURCE_PASSWORD' "${neutral_render}"
grep -q 'name: QUARKUS_DATASOURCE_JDBC_URL' "${neutral_render}"
grep -q 'key: db-jdbc-url' "${neutral_render}"

# Framework generalization: default probe paths and datasource env var names
# follow each service's own framework: convention, not a hardcoded Quarkus one.
grep -q 'name: SPRING_DATASOURCE_USERNAME' "${neutral_render}"
grep -q 'name: SPRING_DATASOURCE_PASSWORD' "${neutral_render}"
grep -q 'name: SPRING_DATASOURCE_URL' "${neutral_render}"
grep -q 'path: /actuator/health/liveness' "${neutral_render}"
grep -q 'path: /actuator/health/readiness' "${neutral_render}"

grep -q 'name: DATASOURCES_DEFAULT_USERNAME' "${neutral_render}"
grep -q 'name: DATASOURCES_DEFAULT_PASSWORD' "${neutral_render}"
grep -q 'name: DATASOURCES_DEFAULT_URL' "${neutral_render}"
grep -q 'path: /health/liveness' "${neutral_render}"
grep -q 'path: /health/readiness' "${neutral_render}"

# QUARKUS_RUNTIME_MODE is a Quarkus packaging convention, not a real config
# property - it must be rendered for the default (quarkus) service and must
# NOT be rendered at all for spring/micronaut services.
if ! awk '/name: evidence-api$/,/^---/' "${neutral_render}" | grep -q 'name: QUARKUS_RUNTIME_MODE'; then
  echo "expected QUARKUS_RUNTIME_MODE for the default-framework (quarkus) service" >&2
  exit 1
fi
if awk '/name: spring-api$/,/^---/' "${neutral_render}" | grep -q 'name: QUARKUS_RUNTIME_MODE'; then
  echo "QUARKUS_RUNTIME_MODE must not be rendered for a spring-framework service" >&2
  exit 1
fi
if awk '/name: micronaut-api$/,/^---/' "${neutral_render}" | grep -q 'name: QUARKUS_RUNTIME_MODE'; then
  echo "QUARKUS_RUNTIME_MODE must not be rendered for a micronaut-framework service" >&2
  exit 1
fi

grep -q 'name: init-container-fixture' "${neutral_render}"
grep -q 'name: publish-contracts' "${neutral_render}"
grep -q 'name: REGISTRY_CLIENT_SECRET' "${neutral_render}"
grep -q 'name: registry-publisher' "${neutral_render}"
grep -q 'key: client-secret' "${neutral_render}"
grep -q 'name: runtime-credential' "${neutral_render}"
grep -q 'secretName: tenant-runtime-credential' "${neutral_render}"
grep -q 'mountPath: "/var/run/secrets/runtime"' "${neutral_render}"
grep -q 'defaultMode: 256' "${neutral_render}"
if grep -q 'name: cloud-sql-proxy' "${neutral_render}"; then
  echo "neutral database rendering unexpectedly contains Cloud SQL" >&2
  exit 1
fi

helm template legacy-test "${chart_dir}" \
  --namespace test \
  -f "${chart_dir}/test-values-list-legacy.yaml" > "${legacy_render}"

grep -q 'name: legacy-api' "${legacy_render}"
grep -q 'image: docker.io/example/legacy-api:test' "${legacy_render}"
grep -q 'name: LEGACY_SETTING' "${legacy_render}"

# ---------------------------------------------------------------------------
# Additive capability gaps closed alongside the fowf Deployment/Job
# migrations: emptyDir volumes, optional secretKeyRef, cloudSqlProxy
# existingSecretName, job-mode probe opt-out, headless Service, release-level
# literal ConfigMaps.
# ---------------------------------------------------------------------------
helm template gaps-test "${chart_dir}" \
  --namespace test \
  -f "${chart_dir}/test-values-gaps.yaml" > "${gaps_render}"

# Gap 1: generic emptyDir volume support.
grep -A3 -q '^      volumes:$' "${gaps_render}"
grep -A2 -q '        - name: tmp$' "${gaps_render}"
grep -q 'sizeLimit: 256Mi' "${gaps_render}"
grep -A2 -q 'name: tmp$' "${gaps_render}"
grep -q 'mountPath: "/tmp"' "${gaps_render}"

# Gap 2: optional flag on secrets[] env-var secretKeyRef injection — one
# entry sets optional: true, a sibling entry omits it and must default false.
grep -q 'key: review-secret' "${gaps_render}"
if ! awk '/key: review-secret/{getline; print; exit}' "${gaps_render}" | grep -q 'optional: true'; then
  echo "expected optional: true immediately after the review-secret secretKeyRef" >&2
  exit 1
fi
grep -q 'key: required-key' "${gaps_render}"
if ! awk '/key: required-key/{getline; print; exit}' "${gaps_render}" | grep -q 'optional: false'; then
  echo "expected optional: false (default) immediately after the required-key secretKeyRef" >&2
  exit 1
fi

# Gap 3: cloudSqlProxy.existingSecretName resolves verbatim, not chart-managed.
grep -q 'name: externally-managed-cloud-sql-secret' "${gaps_render}"
if grep -q 'gaps-test-cloudsql-existing-secret-fixture' "${gaps_render}"; then
  echo "cloudSqlProxy.existingSecretName must bypass the chart-managed <release>-<secretName> name" >&2
  exit 1
fi

# Gap 4: deploymentMode: job defaults probes off; explicit probes.enabled: true opts back in.
if awk '/^# Job: job-probes-off-fixture$/,/^---$/' "${gaps_render}" | grep -q 'Probe:'; then
  echo "deploymentMode: job must default probes off (no liveness/readiness/startupProbe)" >&2
  exit 1
fi
if ! awk '/^# Job: job-probes-optin-fixture$/,/^---$/' "${gaps_render}" | grep -q 'startupProbe:'; then
  echo "deploymentMode: job with probes.enabled: true must still render probes" >&2
  exit 1
fi
# Sibling non-job modes are unaffected — probes still default on.
grep -q 'name: emptydir-fixture$' "${gaps_render}"
if ! awk '/^# Deployment: emptydir-fixture$/,/^---$/' "${gaps_render}" | grep -q 'startupProbe:'; then
  echo "deploymentMode: deployment must still default probes on" >&2
  exit 1
fi

# Gap 5: headless Service via service.clusterIP: "None".
if ! awk '/^# Service: headless-service-fixture$/,/^---$/' "${gaps_render}" | grep -q '^  clusterIP: None$'; then
  echo "service.clusterIP: \"None\" must render clusterIP: None on the Service" >&2
  exit 1
fi
# Sibling non-headless Service is unaffected — no clusterIP field at all.
if awk '/^# Service: optional-secret-fixture$/,/^---$/' "${gaps_render}" | grep -q 'clusterIP:'; then
  echo "a service without service.clusterIP must not render a clusterIP field" >&2
  exit 1
fi

# Gap 6: release-level literal ConfigMap, created and mounted within one release.
grep -q 'name: gaps-test-bootstrap-script' "${gaps_render}"
grep -q 'bootstrap.sh:' "${gaps_render}"
grep -q 'configMapName: gaps-test-bootstrap-script\|name: gaps-test-bootstrap-script' "${gaps_render}"

# Gap 7: telemetry.injectJava per-service override renders the real
# OpenTelemetry Operator pod annotation; a sibling service with no override
# (the chart-level default is false, untouched at the top of this fixture
# file) must not render it at all.
if ! awk '/^# Deployment: telemetry-injectjava-fixture$/,/^---$/' "${gaps_render}" | grep -q 'instrumentation.opentelemetry.io/inject-java: "true"'; then
  echo "telemetry.injectJava: true must render the inject-java pod annotation" >&2
  exit 1
fi
if awk '/^# Deployment: emptydir-fixture$/,/^---$/' "${gaps_render}" | grep -q 'instrumentation.opentelemetry.io/inject-java'; then
  echo "a service with no telemetry.injectJava override must not render the inject-java annotation" >&2
  exit 1
fi

# Gap 8: podDisruptionBudget per-service override renders a real
# PodDisruptionBudget with the requested minAvailable; a sibling service
# with no override (chart-level default is enabled: false) renders none.
if ! awk '/^# PodDisruptionBudget: pdb-minavailable-fixture$/,/^---$/' "${gaps_render}" | grep -q '^  minAvailable: 2$'; then
  echo "podDisruptionBudget.enabled with minAvailable: 2 must render minAvailable: 2" >&2
  exit 1
fi
if grep -q '^# PodDisruptionBudget: emptydir-fixture$' "${gaps_render}"; then
  echo "a service with no podDisruptionBudget override must not render a PodDisruptionBudget" >&2
  exit 1
fi
# Gap 8: enabled with neither minAvailable nor maxUnavailable set defaults
# to maxUnavailable: 1.
if ! awk '/^# PodDisruptionBudget: pdb-default-fixture$/,/^---$/' "${gaps_render}" | grep -q '^  maxUnavailable: 1$'; then
  echo "podDisruptionBudget.enabled with neither field set must default to maxUnavailable: 1" >&2
  exit 1
fi

# Gap 9: podAntiAffinity per-service override renders a soft
# podAntiAffinity rule scoped to this service's own selector labels; a
# sibling service with no override renders no affinity block at all.
if ! awk '/^# Deployment: antiaffinity-fixture$/,/^---$/' "${gaps_render}" | grep -q 'podAntiAffinity:'; then
  echo "podAntiAffinity.enabled: true must render a podAntiAffinity block" >&2
  exit 1
fi
if ! awk '/^# Deployment: antiaffinity-fixture$/,/^---$/' "${gaps_render}" | grep -q 'app.kubernetes.io/component: antiaffinity-fixture'; then
  echo "podAntiAffinity block must scope its labelSelector to this service's own component label" >&2
  exit 1
fi
if awk '/^# Deployment: emptydir-fixture$/,/^---$/' "${gaps_render}" | grep -q 'podAntiAffinity:'; then
  echo "a service with no podAntiAffinity override must not render an affinity block" >&2
  exit 1
fi

echo "java-microservice chart tests passed"
