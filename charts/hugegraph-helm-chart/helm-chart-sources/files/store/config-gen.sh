#!/usr/bin/env sh
set -eu

# ---------------------------------------------------------------------------
# Store config-gen.sh
#
# Generates /config/application.yaml for hugegraph-store.
#
# grpc.host and raft.address use stable headless service DNS names
# instead of pod IPs, preventing Raft conf corruption on pod reschedule.
# ---------------------------------------------------------------------------

require_env() {
  var="$1"
  eval "val=\${$var:-}"
  if [ -z "$val" ]; then
    echo "[config-gen] Missing required env: $var" >&2
    exit 1
  fi
}

require_env POD_NAME
require_env POD_IP
require_env POD_NAMESPACE
require_env STORE_RAFT_PORT
require_env PD_HTTP_PORT
require_env PD_REPLICA_COUNT
require_env WAIT_POLL_SECONDS
require_env WAIT_TIMEOUT_SECONDS
require_env PD_ADDRS

NS="${POD_NAMESPACE}"

# Stable DNS name for this store pod — survives reschedule
SELF_DNS="hugegraph-store-${POD_NAME##*-}.hugegraph-store.${NS}.svc.cluster.local"
RAFT_ADDRESS="${SELF_DNS}:${STORE_RAFT_PORT}"

echo "[config-gen] Self: ${POD_NAME} -> ${SELF_DNS} (IP: ${POD_IP})"

echo "[wait-for-pd] Waiting for PD cluster..."
i=0
while [ "$i" -lt "$PD_REPLICA_COUNT" ]; do
  PD_NAME="hugegraph-pd-${i}"
  PD_URL="http://${PD_NAME}.hugegraph-pd.${NS}.svc.cluster.local:${PD_HTTP_PORT}/actuator/health"
  echo "[wait-for-pd] Waiting for ${PD_NAME} at ${PD_URL}"

  START_TS=$(date +%s)
  while true; do
    if wget -qO- "${PD_URL}" 2>/dev/null | grep -q '"status":"UP"'; then
      echo "[wait-for-pd] ${PD_NAME} is UP"
      break
    fi

    NOW=$(date +%s)
    if [ $((NOW - START_TS)) -ge "${WAIT_TIMEOUT_SECONDS}" ]; then
      echo "[wait-for-pd] Timed out waiting for ${PD_NAME}" >&2
      exit 1
    fi

    sleep "${WAIT_POLL_SECONDS}"
  done

  i=$((i + 1))
done

echo "[wait-for-pd] All PD nodes ready"

mkdir -p /config

sed \
  -e "s#__PD_ADDRS__#${PD_ADDRS}#g" \
  -e "s#__SELF_DNS__#${SELF_DNS}#g" \
  -e "s#__RAFT_ADDRESS__#${RAFT_ADDRESS}#g" \
  /templates/application.yaml.tpl > /config/application.yaml

echo "[config-gen] Generated /config/application.yaml"
echo "[config-gen] grpc.host=${SELF_DNS}"
echo "[config-gen] raft.address=${RAFT_ADDRESS}"
cat /config/application.yaml