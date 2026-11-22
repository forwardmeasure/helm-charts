#!/usr/bin/env bash
set -euo pipefail

# Waits for the PostgreSQL server to accept connections, for as long as that takes. The import Job
# runs it before importing. Waiting for an import to finish is the chart's own API wait
# (templates/_helpers.tpl geocoding.waitForImportScript), which never gives up on a clock.

: "${PGHOST:?PGHOST is required}"
: "${PGPORT:?PGPORT is required}"
: "${PGDATABASE:?PGDATABASE is required}"
: "${PGUSER:?PGUSER is required}"

WAIT_SLEEP_SECONDS="${WAIT_SLEEP_SECONDS:-5}"
WAIT_DATABASE="${WAIT_DATABASE:-${PGDATABASE}}"

echo "Waiting for Postgres at ${PGHOST}:${PGPORT}/${WAIT_DATABASE}"
until pg_isready -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${WAIT_DATABASE}"; do
  sleep "${WAIT_SLEEP_SECONDS}"
done
