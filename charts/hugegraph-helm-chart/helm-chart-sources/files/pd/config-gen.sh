#!/usr/bin/env sh
set -eu

# ---------------------------------------------------------------------------
# PD config-gen.sh
#
# Generates /config/application.yaml for hugegraph-pd.
#
# Raft peer list and self-address use stable headless service DNS names
# instead of pod IPs. This prevents Raft conf corruption when pods are
# rescheduled to different nodes and get new IPs.
#
# The kubectl dependency is retained only to wait for peer pods to exist
# before proceeding — we no longer use the IP for anything.
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
require_env PD_REPLICA_COUNT
require_env PD_RAFT_PORT
require_env PD_POLL_SECONDS
require_env PD_TIMEOUT_SECONDS
require_env STORE_GRPC_LIST

NS="${POD_NAMESPACE}"

# Self DNS name — stable across reschedules
SELF_DNS="hugegraph-pd-${POD_NAME##*-}.hugegraph-pd.${NS}.svc.cluster.local"

echo "[config-gen] Self: ${POD_NAME} -> ${SELF_DNS} (IP: ${POD_IP})"

i=0
RAFT_PEERS=""
while [ "$i" -lt "$PD_REPLICA_COUNT" ]; do
  PEER_NAME="hugegraph-pd-${i}"
  PEER_DNS="hugegraph-pd-${i}.hugegraph-pd.${NS}.svc.cluster.local"

  if [ "${POD_NAME}" = "${PEER_NAME}" ]; then
    echo "[config-gen] Self peer ${PEER_NAME} -> ${PEER_DNS}"
  else
    # Wait for peer pod to exist and have an IP — we only need this to
    # ensure the peer is scheduled before we proceed, not to use the IP.
    echo "[config-gen] Waiting for ${PEER_NAME} to be scheduled..."
    START_TS=$(date +%s)
    while true; do
      PEER_IP=$(kubectl get pod "${PEER_NAME}" -n "${NS}" \
        -o jsonpath='{.status.podIP}' 2>/dev/null || true)
      if [ -n "${PEER_IP}" ]; then
        echo "[config-gen] ${PEER_NAME} is scheduled (DNS: ${PEER_DNS})"
        break
      fi

      NOW=$(date +%s)
      if [ $((NOW - START_TS)) -ge "${PD_TIMEOUT_SECONDS}" ]; then
        echo "[config-gen] Timed out waiting for ${PEER_NAME} to be scheduled" >&2
        exit 1
      fi

      sleep "${PD_POLL_SECONDS}"
    done
  fi

  # Always use DNS name — never the IP
  if [ -z "${RAFT_PEERS}" ]; then
    RAFT_PEERS="${PEER_DNS}:${PD_RAFT_PORT}"
  else
    RAFT_PEERS="${RAFT_PEERS},${PEER_DNS}:${PD_RAFT_PORT}"
  fi

  i=$((i + 1))
done

mkdir -p /config

sed \
  -e "s/__SELF_DNS__/${SELF_DNS}/g" \
  -e "s#__RAFT_PEERS__#${RAFT_PEERS}#g" \
  -e "s#__STORE_LIST__#${STORE_GRPC_LIST}#g" \
  /templates/application.yaml.tpl > /config/application.yaml

echo "[config-gen] Generated /config/application.yaml"
echo "[config-gen] raft.address=${SELF_DNS}:${PD_RAFT_PORT}"
echo "[config-gen] peers=${RAFT_PEERS}"
cat /config/application.yaml
