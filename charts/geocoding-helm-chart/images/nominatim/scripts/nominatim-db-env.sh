#!/usr/bin/env bash
set -euo pipefail

: "${PGHOST:?PGHOST is required}"
: "${PGPORT:?PGPORT is required}"
: "${PGDATABASE:?PGDATABASE is required}"
: "${PGUSER:?PGUSER is required}"
: "${PGPASSWORD:?PGPASSWORD is required}"
export PGMAINTENANCEDATABASE="${PGMAINTENANCEDATABASE:-postgres}"

if [ -z "${NOMINATIM_DATABASE_DSN:-}" ]; then
  NOMINATIM_DATABASE_DSN="pgsql:dbname=${PGDATABASE};host=${PGHOST};port=${PGPORT};user=${PGUSER};password=${PGPASSWORD}"
  if [ -n "${PGSSLMODE:-}" ]; then
    NOMINATIM_DATABASE_DSN="${NOMINATIM_DATABASE_DSN};sslmode=${PGSSLMODE}"
  fi
  export NOMINATIM_DATABASE_DSN
fi

export NOMINATIM_DATABASE_WEBUSER="${NOMINATIM_DATABASE_WEBUSER:-nominatim}"
export NOMINATIM_PROJECT_DIR="${PROJECT_DIR:-/nominatim}"
