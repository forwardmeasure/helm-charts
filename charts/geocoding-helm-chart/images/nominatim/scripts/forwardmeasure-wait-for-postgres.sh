#!/usr/bin/env bash
set -euo pipefail

: "${PGHOST:?PGHOST is required}"
: "${PGPORT:?PGPORT is required}"
: "${PGDATABASE:?PGDATABASE is required}"
: "${PGUSER:?PGUSER is required}"

WAIT_SLEEP_SECONDS="${WAIT_SLEEP_SECONDS:-5}"
WAIT_FOR_IMPORT="${WAIT_FOR_IMPORT:-false}"
WAIT_FOR_IMPORT_TIMEOUT_SECONDS="${WAIT_FOR_IMPORT_TIMEOUT_SECONDS:-7200}"
WAIT_DATABASE="${WAIT_DATABASE:-${PGDATABASE}}"

echo "Waiting for Postgres at ${PGHOST}:${PGPORT}/${WAIT_DATABASE}"
until pg_isready -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${WAIT_DATABASE}"; do
  sleep "${WAIT_SLEEP_SECONDS}"
done

if [ "${WAIT_FOR_IMPORT}" = "true" ]; then
  started_at="$(date +%s)"
  while true; do
    if psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" -tAc "select value from nominatim_properties where property = 'database_version'" 2>/dev/null | grep -q .; then
      echo "Nominatim import completion marker found"
      break
    fi

    now="$(date +%s)"
    elapsed="$((now - started_at))"
    if [ "${elapsed}" -ge "${WAIT_FOR_IMPORT_TIMEOUT_SECONDS}" ]; then
      echo "Timed out waiting for Nominatim import completion marker"
      exit 1
    fi
    sleep 10
  done
fi
