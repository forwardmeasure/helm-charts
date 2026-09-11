#!/usr/bin/env bash
set -euo pipefail

chart_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
map_render="$(mktemp)"
neutral_render="$(mktemp)"
legacy_render="$(mktemp)"
trap 'rm -f "${map_render}" "${neutral_render}" "${legacy_render}"' EXIT

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

echo "java-microservice chart tests passed"
