#!/usr/bin/env bash
set -euo pipefail
tests_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
chart_dir="${tests_dir}/../helm-chart-sources"
helm lint --strict "${chart_dir}"
python3 -B "${tests_dir}/test_chart.py"
