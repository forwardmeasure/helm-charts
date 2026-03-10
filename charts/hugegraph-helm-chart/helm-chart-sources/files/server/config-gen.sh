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
require_env HTTP_PORT
require_env GREMLIN_PORT
require_env RPC_PORT
require_env PD_HTTP_PORT
require_env PD_REPLICA_COUNT
require_env STORE_HTTP_PORT
require_env STORE_REPLICA_COUNT
require_env WAIT_POLL_SECONDS
require_env WAIT_TIMEOUT_SECONDS
require_env PD_ADDRS
require_env SERVER_ROLE_MASTER
require_env SERVER_ROLE_WORKER
require_env TASK_SCHEDULER_TYPE
require_env GRAPH_BACKEND
require_env GRAPH_SERIALIZER
require_env GRAPH_STORE
require_env VERTEX_CACHE_TYPE
require_env EDGE_CACHE_TYPE
require_env AUTH_ENABLED
require_env SLOW_QUERY_THRESHOLD

NS="${POD_NAMESPACE}"
ORDINAL="${POD_NAME##*-}"

if [ "${ORDINAL}" = "0" ]; then
  SERVER_ROLE="${SERVER_ROLE_MASTER}"
else
  SERVER_ROLE="${SERVER_ROLE_WORKER}"
fi

SERVER_ID="${POD_NAME}"

wait_http_up() {
  name="$1"
  url="$2"
  echo "[wait] Waiting for ${name} at ${url}"
  start_ts="$(date +%s)"
  while true; do
    if wget -qO- "${url}" 2>/dev/null | grep -q '"status":"UP"'; then
      echo "[wait] ${name} is UP"
      return 0
    fi

    now="$(date +%s)"
    if [ $((now - start_ts)) -ge "${WAIT_TIMEOUT_SECONDS}" ]; then
      echo "[wait] Timed out waiting for ${name}" >&2
      exit 1
    fi

    sleep "${WAIT_POLL_SECONDS}"
  done
}

wait_tcp_up() {
  name="$1"
  host="$2"
  port="$3"
  echo "[wait] Waiting for ${name} at ${host}:${port}"
  start_ts="$(date +%s)"
  while true; do
    if nc -z "${host}" "${port}" >/dev/null 2>&1; then
      echo "[wait] ${name} is reachable on ${host}:${port}"
      return 0
    fi

    now="$(date +%s)"
    if [ $((now - start_ts)) -ge "${WAIT_TIMEOUT_SECONDS}" ]; then
      echo "[wait] Timed out waiting for ${name}" >&2
      exit 1
    fi

    sleep "${WAIT_POLL_SECONDS}"
  done
}

echo "[wait] Waiting for PD..."
i=0
while [ "$i" -lt "$PD_REPLICA_COUNT" ]; do
  PD_NAME="hugegraph-pd-${i}"
  PD_URL="http://${PD_NAME}.hugegraph-pd.${NS}.svc.cluster.local:${PD_HTTP_PORT}/actuator/health"
  wait_http_up "${PD_NAME}" "${PD_URL}"
  i=$((i + 1))
done

echo "[wait] Waiting for STORE..."
i=0
while [ "$i" -lt "$STORE_REPLICA_COUNT" ]; do
  STORE_NAME="hugegraph-store-${i}"
  STORE_HOST="${STORE_NAME}.hugegraph-store.${NS}.svc.cluster.local"
  wait_tcp_up "${STORE_NAME}" "${STORE_HOST}" "${STORE_HTTP_PORT}"
  i=$((i + 1))
done

mkdir -p /config/graphs

sed \
  -e "s#__GREMLIN_PORT__#${GREMLIN_PORT}#g" \
  -e "s#__RPC_PORT__#${RPC_PORT}#g" \
  /templates/gremlin-server.yaml.tpl > /config/gremlin-server.yaml

sed \
  -e "s#__HTTP_PORT__#${HTTP_PORT}#g" \
  -e "s#__SLOW_QUERY_THRESHOLD__#${SLOW_QUERY_THRESHOLD}#g" \
  /templates/rest-server.properties.tpl > /config/rest-server.properties

sed \
  -e "s#__PD_ADDRS__#${PD_ADDRS}#g" \
  -e "s#__SERVER_ID__#${SERVER_ID}#g" \
  -e "s#__SERVER_ROLE__#${SERVER_ROLE}#g" \
  -e "s#__TASK_SCHEDULER_TYPE__#${TASK_SCHEDULER_TYPE}#g" \
  -e "s#__GRAPH_BACKEND__#${GRAPH_BACKEND}#g" \
  -e "s#__GRAPH_SERIALIZER__#${GRAPH_SERIALIZER}#g" \
  -e "s#__GRAPH_STORE__#${GRAPH_STORE}#g" \
  -e "s#__VERTEX_CACHE_TYPE__#${VERTEX_CACHE_TYPE}#g" \
  -e "s#__EDGE_CACHE_TYPE__#${EDGE_CACHE_TYPE}#g" \
  -e "s#__AUTH_ENABLED__#${AUTH_ENABLED}#g" \
  /templates/hugegraph.properties.tpl > /config/graphs/hugegraph.properties

echo "[config-gen] Generated /config/rest-server.properties"
cat /config/rest-server.properties
echo "[config-gen] Generated /config/gremlin-server.yaml"
cat /config/gremlin-server.yaml
echo "[config-gen] Generated /config/graphs/hugegraph.properties"
cat /config/graphs/hugegraph.properties