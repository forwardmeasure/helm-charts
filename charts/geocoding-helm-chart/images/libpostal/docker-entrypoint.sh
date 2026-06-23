#!/usr/bin/env sh
set -eu

host="${LIBPOSTAL_HOST:-0.0.0.0}"
port="${LIBPOSTAL_PORT:-4400}"

exec /usr/local/bin/wof-libpostal-server -host "${host}" -port "${port}" "$@"
