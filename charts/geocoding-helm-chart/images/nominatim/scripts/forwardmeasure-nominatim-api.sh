#!/usr/bin/env bash
set -euo pipefail

. /usr/local/lib/forwardmeasure/nominatim-db-env.sh

PROJECT_DIR="${PROJECT_DIR:-/nominatim}"
NOMINATIM_HTTP_PORT="${NOMINATIM_HTTP_PORT:-8080}"
GUNICORN_WORKERS="${GUNICORN_WORKERS:-2}"
NOMINATIM_REFRESH_ON_STARTUP="${NOMINATIM_REFRESH_ON_STARTUP:-true}"

cd "${PROJECT_DIR}"

run_as_nominatim() {
  if [ "$(id -u)" = "0" ]; then
    gosu nominatim "$@"
  else
    "$@"
  fi
}

if [ "${NOMINATIM_REFRESH_ON_STARTUP}" = "true" ]; then
  run_as_nominatim nominatim refresh --website --functions
fi

if [ "$(id -u)" = "0" ]; then
  exec gosu nominatim gunicorn \
    --bind ":${NOMINATIM_HTTP_PORT}" \
    --workers "${GUNICORN_WORKERS}" \
    --worker-class asgi \
    --worker-connections 1000 \
    "nominatim_api.server.falcon.server:run_wsgi()"
fi

exec gunicorn \
  --bind ":${NOMINATIM_HTTP_PORT}" \
  --workers "${GUNICORN_WORKERS}" \
  --worker-class asgi \
  --worker-connections 1000 \
  "nominatim_api.server.falcon.server:run_wsgi()"
