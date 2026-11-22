#!/usr/bin/env bash
set -euo pipefail

# Waits for the PostgreSQL server, a dependency, to accept connections. The import Job runs it before
# importing. pg_isready is tried up to DATABASE_WAIT_ATTEMPTS times, each attempt bounded by
# DATABASE_WAIT_CONNECT_TIMEOUT_SECONDS, with exponential back-off from
# DATABASE_WAIT_INITIAL_BACKOFF_SECONDS, multiplied by DATABASE_WAIT_BACKOFF_MULTIPLIER, up to
# DATABASE_WAIT_MAXIMUM_BACKOFF_SECONDS; then it fails naming the database. The values come from the
# chart (nominatim.databaseWait); the script holds none.

: "${PGHOST:?PGHOST is required}"
: "${PGPORT:?PGPORT is required}"
: "${PGDATABASE:?PGDATABASE is required}"
: "${PGUSER:?PGUSER is required}"
: "${DATABASE_WAIT_ATTEMPTS:?DATABASE_WAIT_ATTEMPTS is required}"
: "${DATABASE_WAIT_CONNECT_TIMEOUT_SECONDS:?DATABASE_WAIT_CONNECT_TIMEOUT_SECONDS is required}"
: "${DATABASE_WAIT_INITIAL_BACKOFF_SECONDS:?DATABASE_WAIT_INITIAL_BACKOFF_SECONDS is required}"
: "${DATABASE_WAIT_MAXIMUM_BACKOFF_SECONDS:?DATABASE_WAIT_MAXIMUM_BACKOFF_SECONDS is required}"
: "${DATABASE_WAIT_BACKOFF_MULTIPLIER:?DATABASE_WAIT_BACKOFF_MULTIPLIER is required}"

WAIT_DATABASE="${WAIT_DATABASE:-${PGDATABASE}}"

attempt=1
backoff="${DATABASE_WAIT_INITIAL_BACKOFF_SECONDS}"
until status="$(pg_isready -t "${DATABASE_WAIT_CONNECT_TIMEOUT_SECONDS}" -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${WAIT_DATABASE}" 2>&1)"; do
  if [ "${attempt}" -ge "${DATABASE_WAIT_ATTEMPTS}" ]; then
    echo "PostgreSQL at ${PGHOST}:${PGPORT} (database ${WAIT_DATABASE}) did not accept connections after ${attempt} attempts: ${status}" >&2
    exit 1
  fi
  echo "Waiting for PostgreSQL at ${PGHOST}:${PGPORT}/${WAIT_DATABASE} (attempt ${attempt} of ${DATABASE_WAIT_ATTEMPTS}, next in ${backoff} s): ${status}"
  sleep "${backoff}"
  backoff=$(( backoff * DATABASE_WAIT_BACKOFF_MULTIPLIER ))
  if [ "${backoff}" -gt "${DATABASE_WAIT_MAXIMUM_BACKOFF_SECONDS}" ]; then
    backoff="${DATABASE_WAIT_MAXIMUM_BACKOFF_SECONDS}"
  fi
  attempt=$(( attempt + 1 ))
done
echo "PostgreSQL at ${PGHOST}:${PGPORT}/${WAIT_DATABASE} accepts connections"
