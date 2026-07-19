#!/usr/bin/env bash
set -euo pipefail
CHART_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
helm lint --strict "$CHART_DIR" --set image.repository=docker.io/example/model-server
RENDERED="$(helm template model-service "$CHART_DIR" --namespace model-serving \
  --values "$CHART_DIR/test-values-grpc.yaml")"
[[ "$RENDERED" == *'appProtocol: "grpc"'* ]]
[[ "$RENDERED" == *'grpc:'* ]]
if [[ "$RENDERED" == *'httpGet:'* ]]; then
  echo "gRPC probe render unexpectedly contains an HTTP probe handler" >&2
  exit 1
fi
echo "model-service chart tests passed"
