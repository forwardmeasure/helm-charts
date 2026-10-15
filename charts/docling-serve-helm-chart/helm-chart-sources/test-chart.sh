#!/usr/bin/env bash
set -euo pipefail
chart_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
helm lint --strict "${chart_dir}"
python3 -B "${chart_dir}/tests/test_chart.py"
