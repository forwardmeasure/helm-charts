#!/usr/bin/env bash
set -euo pipefail

chart_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
map_render="$(mktemp)"
legacy_render="$(mktemp)"
trap 'rm -f "${map_render}" "${legacy_render}"' EXIT

helm lint "${chart_dir}"

helm template map-test "${chart_dir}" \
  --namespace test \
  -f "${chart_dir}/test-values-map-base.yaml" \
  -f "${chart_dir}/test-values-map-gcp.yaml" > "${map_render}"

grep -q 'name: evidence-api' "${map_render}"
grep -q 'image: docker.io/example/evidence-api:test' "${map_render}"
grep -q 'name: BASE_SETTING' "${map_render}"
grep -q 'value: "retained"' "${map_render}"
grep -q 'name: GCP_PROJECT_ID' "${map_render}"
grep -q 'value: "test-project"' "${map_render}"

helm template legacy-test "${chart_dir}" \
  --namespace test \
  -f "${chart_dir}/test-values-list-legacy.yaml" > "${legacy_render}"

grep -q 'name: legacy-api' "${legacy_render}"
grep -q 'image: docker.io/example/legacy-api:test' "${legacy_render}"
grep -q 'name: LEGACY_SETTING' "${legacy_render}"

echo "quarkus-service chart tests passed"
