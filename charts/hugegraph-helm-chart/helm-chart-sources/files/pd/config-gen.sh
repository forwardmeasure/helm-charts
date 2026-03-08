#!/usr/bin/env sh
set -eu

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
require_env PD_REPLICA_COUNT
require_env PD_RAFT_PORT
require_env PD_POLL_SECONDS
require_env PD_TIMEOUT_SECONDS
require_env STORE_GRPC_LIST

SELF_IP="${POD_IP}"
NS="${POD_NAMESPACE}"

echo "[config-gen] Self: ${POD_NAME} -> ${SELF_IP}"

i=0
RAFT_PEERS=""
while [ "$i" -lt "$PD_REPLICA_COUNT" ]; do
  PEER_NAME="hugegraph-pd-${i}"

  if [ "${POD_NAME}" = "${PEER_NAME}" ]; then
    IP="${SELF_IP}"
    echo "[config-gen] Self peer ${PEER_NAME} -> ${IP}"
  else
    echo "[config-gen] Waiting for ${PEER_NAME} pod IP..."
    START_TS=$(date +%s)
    while true; do
      IP=$(kubectl get pod "${PEER_NAME}" -n "${NS}" -o jsonpath='{.status.podIP}' 2>/dev/null || true)
      if [ -n "${IP}" ]; then
        echo "[config-gen] ${PEER_NAME} -> ${IP}"
        break
      fi

      NOW=$(date +%s)
      if [ $((NOW - START_TS)) -ge "${PD_TIMEOUT_SECONDS}" ]; then
        echo "[config-gen] Timed out waiting for ${PEER_NAME} pod IP" >&2
        exit 1
      fi

      sleep "${PD_POLL_SECONDS}"
    done
  fi

  if [ -z "${RAFT_PEERS}" ]; then
    RAFT_PEERS="${IP}:${PD_RAFT_PORT}"
  else
    RAFT_PEERS="${RAFT_PEERS},${IP}:${PD_RAFT_PORT}"
  fi

  i=$((i + 1))
done

mkdir -p /config

sed \
  -e "s/__SELF_IP__/${SELF_IP}/g" \
  -e "s#__RAFT_PEERS__#${RAFT_PEERS}#g" \
  -e "s#__STORE_LIST__#${STORE_GRPC_LIST}#g" \
  /templates/application.yaml.tpl > /config/application.yaml

echo "[config-gen] Generated /config/application.yaml"
echo "[config-gen] raft.address=${SELF_IP}:${PD_RAFT_PORT}"
echo "[config-gen] peers=${RAFT_PEERS}"
cat /config/application.yaml