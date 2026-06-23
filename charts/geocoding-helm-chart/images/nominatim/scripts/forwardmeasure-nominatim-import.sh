#!/usr/bin/env bash
set -euo pipefail

. /usr/local/lib/forwardmeasure/nominatim-db-env.sh
WAIT_DATABASE="${PGMAINTENANCEDATABASE:-postgres}" /usr/local/bin/forwardmeasure-wait-for-postgres

PROJECT_DIR="${PROJECT_DIR:-/nominatim}"
PBF_URL="${PBF_URL:-}"
PBF_PATH="${PBF_PATH:-}"
USER_AGENT="${USER_AGENT:-forwardmeasure-geocoding}"
THREADS="${THREADS:-4}"
REVERSE_ONLY="${REVERSE_ONLY:-false}"
NOMINATIM_IMPORT_FLAGS="${NOMINATIM_IMPORT_FLAGS:-}"
NOMINATIM_IMPORT_MODE="${NOMINATIM_IMPORT_MODE:-create}"
NOMINATIM_IMPORT_CONTINUE_STEP="${NOMINATIM_IMPORT_CONTINUE_STEP:-import-from-file}"
SKIP_IF_IMPORTED="${SKIP_IF_IMPORTED:-true}"
RUN_CHECK_DATABASE="${RUN_CHECK_DATABASE:-true}"
ANALYZE="${ANALYZE:-true}"
WARM="${WARM:-false}"
CLEANUP_DOWNLOADED_PBF="${CLEANUP_DOWNLOADED_PBF:-true}"
REPLICATION_URL="${REPLICATION_URL:-${NOMINATIM_REPLICATION_URL:-}}"
FREEZE="${FREEZE:-false}"

run_as_nominatim() {
  if [ "$(id -u)" = "0" ]; then
    gosu nominatim "$@"
  else
    "$@"
  fi
}

if [ "${SKIP_IF_IMPORTED}" = "true" ]; then
  if psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" -tAc "select to_regclass('public.placex')" | grep -q placex; then
    echo "Nominatim database already contains placex; skipping import"
    exit 0
  fi
fi

OSMFILE="${PBF_PATH}"
if [ -n "${PBF_URL}" ]; then
  OSMFILE="${PROJECT_DIR}/data.osm.pbf"
  echo "Downloading OSM extract from ${PBF_URL}"
  curl -L -A "${USER_AGENT}" --fail --create-dirs -o "${OSMFILE}" "${PBF_URL}"
fi

if [ -z "${OSMFILE}" ]; then
  echo "PBF_URL or PBF_PATH must be set"
  exit 1
fi

if [ "$(id -u)" = "0" ]; then
  chown -R nominatim:nominatim "${PROJECT_DIR}"
fi
cd "${PROJECT_DIR}"

import_args=(import --osm-file "${OSMFILE}" --threads "${THREADS}")
case "${NOMINATIM_IMPORT_MODE}" in
  create)
    ;;
  continue)
    if [[ "${NOMINATIM_IMPORT_FLAGS}" != *"--continue"* ]]; then
      import_args+=(--continue "${NOMINATIM_IMPORT_CONTINUE_STEP}")
    fi
    ;;
  *)
    echo "Unsupported NOMINATIM_IMPORT_MODE: ${NOMINATIM_IMPORT_MODE}"
    exit 1
    ;;
esac
if [ "${REVERSE_ONLY}" = "true" ]; then
  import_args+=(--reverse-only)
fi
if [ -n "${NOMINATIM_IMPORT_FLAGS}" ]; then
  read -r -a extra_import_args <<< "${NOMINATIM_IMPORT_FLAGS}"
  import_args+=("${extra_import_args[@]}")
fi

echo "Running Nominatim import"
run_as_nominatim nominatim "${import_args[@]}"

if [ -f tiger-nominatim-preprocessed.csv.tar.gz ]; then
  run_as_nominatim nominatim add-data --tiger-data tiger-nominatim-preprocessed.csv.tar.gz
fi

run_as_nominatim nominatim index --threads "${THREADS}"
run_as_nominatim nominatim refresh --website --functions

if [ "${RUN_CHECK_DATABASE}" = "true" ]; then
  run_as_nominatim nominatim admin --check-database
fi

if [ -n "${REPLICATION_URL}" ]; then
  run_as_nominatim nominatim replication --project-dir "${PROJECT_DIR}" --init
elif [ "${FREEZE}" = "true" ]; then
  run_as_nominatim nominatim freeze
fi

if [ "${WARM}" = "true" ]; then
  run_as_nominatim nominatim admin --warm
fi

if [ "${ANALYZE}" = "true" ]; then
  psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" -c "ANALYZE VERBOSE"
fi

if [ "${CLEANUP_DOWNLOADED_PBF}" = "true" ] && [ -n "${PBF_URL}" ]; then
  rm -f "${OSMFILE}"
fi
