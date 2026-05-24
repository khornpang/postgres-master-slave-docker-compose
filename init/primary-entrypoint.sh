#!/bin/sh
# Primary entrypoint wrapper. The postgres image's initdb step reads
# POSTGRES_DB to create the bootstrap database; we derive that name from
# the first entry of POSTGRES_DBS so the rest of the stack can read a
# single comma-separated list. init-primary.sh creates the remaining
# databases after initdb completes.
set -eu

: "${POSTGRES_DBS:=monitor}"

FIRST_DB=$(printf '%s' "$POSTGRES_DBS" | cut -d, -f1 | tr -d '[:space:]')
if [ -z "$FIRST_DB" ]; then
  echo "[primary-entrypoint] ERROR: POSTGRES_DBS is empty after parsing" >&2
  exit 1
fi

export POSTGRES_DB="$FIRST_DB"
echo "[primary-entrypoint] POSTGRES_DBS=$POSTGRES_DBS"
echo "[primary-entrypoint] bootstrap POSTGRES_DB=$POSTGRES_DB"

# Read secrets HERE, while still running as root, and export them as env vars.
# docker-entrypoint.sh switches to the postgres OS user via gosu before
# running docker-entrypoint-initdb.d scripts. That postgres user cannot read
# 0600 root:root secret files directly, so we pre-read them here and let
# init-primary.sh consume the env vars instead.
_read_secret() { tr -d '\n\r' < "/run/secrets/$1"; }
export REPLICATION_PASSWORD="$(_read_secret replication_password)"
export READONLY_PASSWORD="$(_read_secret readonly_password)"
export PGBOUNCER_AUTH_PASSWORD="$(_read_secret pgbouncer_auth_password)"

# Docker named volumes are created root:root mode 755. The postgres user
# needs to write to the log dir (logging_collector) and the WAL archive
# dir (archive_command) BEFORE postgres starts, otherwise initdb's
# temporary server startup fails and the init scripts never run.
# init-primary.sh repeats these chowns defensively at the end of init.
for d in /var/log/postgresql /var/lib/postgresql/archive; do
  mkdir -p "$d"
  chown -R postgres:postgres "$d"
  chmod 0750 "$d"
done

exec docker-entrypoint.sh "$@"
