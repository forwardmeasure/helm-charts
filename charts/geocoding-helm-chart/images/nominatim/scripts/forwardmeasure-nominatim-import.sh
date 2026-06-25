#!/usr/bin/env bash
set -euo pipefail

. /usr/local/lib/forwardmeasure/nominatim-db-env.sh
WAIT_DATABASE="${PGMAINTENANCEDATABASE:-postgres}" /usr/local/bin/forwardmeasure-wait-for-postgres

PROJECT_DIR="${PROJECT_DIR:-/nominatim}"
PBF_URLS="${PBF_URLS:-}"
PBF_PATH="${PBF_PATH:-}"
PBF_PATHS="${PBF_PATHS:-}"
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

append_csv() {
  local csv="${1:-}"
  local -n target="$2"
  local item
  local -a items

  if [ -z "${csv}" ]; then
    return
  fi

  IFS=',' read -r -a items <<< "${csv}"
  for item in "${items[@]}"; do
    item="${item#"${item%%[![:space:]]*}"}"
    item="${item%"${item##*[![:space:]]}"}"
    if [ -n "${item}" ]; then
      target+=("${item}")
    fi
  done
}

if [ "${SKIP_IF_IMPORTED}" = "true" ]; then
  if psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" -tAc "select to_regclass('public.placex')" | grep -q placex; then
    echo "Nominatim database already contains placex; skipping import"
    exit 0
  fi
fi

source_files=()
downloaded_files=()
pbf_urls=()
pbf_paths=()

append_csv "${PBF_URLS}" pbf_urls
append_csv "${PBF_PATHS}" pbf_paths

if [ "${#pbf_paths[@]}" -eq 0 ] && [ -n "${PBF_PATH}" ]; then
  pbf_paths+=("${PBF_PATH}")
fi

if [ "${#pbf_urls[@]}" -eq 0 ] && [ "${#pbf_paths[@]}" -eq 0 ]; then
  echo "PBF_PATH, PBF_URLS, or PBF_PATHS must be set"
  exit 1
fi

mkdir -p "${PROJECT_DIR}/extracts"

for url in "${pbf_urls[@]}"; do
  idx="${#downloaded_files[@]}"
  file="${PROJECT_DIR}/extracts/extract-${idx}.osm.pbf"
  echo "Downloading OSM extract from ${url}"
  curl -L -A "${USER_AGENT}" --fail --retry 5 --retry-delay 15 --retry-connrefused \
    --continue-at - --create-dirs -o "${file}" "${url}"
  source_files+=("${file}")
  downloaded_files+=("${file}")
done

for path in "${pbf_paths[@]}"; do
  if [ ! -f "${path}" ]; then
    echo "PBF path does not exist: ${path}"
    exit 1
  fi
  source_files+=("${path}")
done

if [ "${#source_files[@]}" -eq 1 ]; then
  OSMFILE="${source_files[0]}"
else
  OSMFILE="${PROJECT_DIR}/merged.osm.pbf"
  echo "Merging ${#source_files[@]} OSM extracts into ${OSMFILE}"
  osmium merge "${source_files[@]}" -o "${OSMFILE}" --overwrite
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

if [ "${CLEANUP_DOWNLOADED_PBF}" = "true" ]; then
  if [ "${#downloaded_files[@]}" -gt 0 ]; then
    rm -f "${downloaded_files[@]}"
  fi
  if [ "${#source_files[@]}" -gt 1 ]; then
    rm -f "${OSMFILE}"
  fi
fi
