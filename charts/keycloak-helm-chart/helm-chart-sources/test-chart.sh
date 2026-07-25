#!/usr/bin/env bash
set -euo pipefail

chart_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
test_values="${chart_dir}/test-values-additional-redirects.yaml"
rendered="$(mktemp)"
root_rendered="$(mktemp)"
trap 'rm -f "${rendered}" "${root_rendered}"' EXIT

helm lint "${chart_dir}" -f "${test_values}"
helm template keycloak "${chart_dir}" -f "${test_values}" > "${rendered}"
helm template keycloak "${chart_dir}" \
  --set-string keycloak.httpRelativePath=/ \
  > "${root_rendered}"
bash -n "${chart_dir}/files/bootstrap-admin.sh"

grep -Fq 'value: "[\"https://agents.datafabric.example.com/*\"]"' "${rendered}"
grep -Fq 'value: "[\"https://agents.datafabric.example.com\"]"' "${rendered}"
grep -Fq 'https://dashboard.datafabric.example.com/*##https://workbench.datafabric.example.com/*##https://agents.datafabric.example.com/*' "${rendered}"
grep -Fq '+ $additionalRedirects' "${rendered}"
grep -Fq '+ $additionalOrigins' "${rendered}"
grep -Fq 'KEYCLOAK_URL="${KEYCLOAK_URL%/}"' "${rendered}"
grep -Fq 'value: "http://keycloak-internal:8080"' "${root_rendered}"
grep -Fq 'path: "/health/ready"' "${root_rendered}"
grep -Fq 'path: "/health/live"' "${root_rendered}"
if grep -Fq 'keycloak-internal:8080/' "${root_rendered}"; then
  echo "Root-context KEYCLOAK_URL contains a trailing slash" >&2
  exit 1
fi

echo "Keycloak chart tests passed."
