#!/usr/bin/env bash
set -euo pipefail

chart_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
test_values="${chart_dir}/test-values-additional-redirects.yaml"
rendered="$(mktemp)"
trap 'rm -f "${rendered}"' EXIT

helm lint "${chart_dir}" -f "${test_values}"
helm template keycloak "${chart_dir}" -f "${test_values}" > "${rendered}"
bash -n "${chart_dir}/files/bootstrap-admin.sh"

grep -Fq 'value: "[\"https://agents.datafabric.example.com/*\"]"' "${rendered}"
grep -Fq 'value: "[\"https://agents.datafabric.example.com\"]"' "${rendered}"
grep -Fq 'https://dashboard.datafabric.example.com/*##https://workbench.datafabric.example.com/*##https://agents.datafabric.example.com/*' "${rendered}"
grep -Fq '+ $additionalRedirects' "${rendered}"
grep -Fq '+ $additionalOrigins' "${rendered}"

echo "Keycloak chart tests passed."
