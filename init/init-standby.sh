#!/bin/bash
# Entrypoint for standby. On first start (empty PGDATA) runs pg_basebackup
# from the primary using a replication slot. On subsequent starts, hands
# off to the normal postgres entrypoint.
set -euo pipefail

PGDATA="${PGDATA:-/var/lib/postgresql/data}"
LOG_DIR="/var/log/postgresql"

mkdir -p "$LOG_DIR"
chown -R postgres:postgres "$LOG_DIR"
chmod 0750 "$LOG_DIR"

if [ ! -s "$PGDATA/PG_VERSION" ]; then
  echo "[init-standby] Data dir empty. Will pg_basebackup from ${PRIMARY_HOST}..."

  REPLICATION_PASSWORD="$(tr -d '\n\r' < /run/secrets/replication_password)"

  mkdir -p "$PGDATA"
  chown -R postgres:postgres "$PGDATA"
  chmod 0700 "$PGDATA"

  # Wait for primary to be ready to accept replication connections
  until PGPASSWORD="$REPLICATION_PASSWORD" \
        gosu postgres pg_isready \
          -h "$PRIMARY_HOST" \
          -p "$PRIMARY_PORT" \
          -U "$REPLICATION_USER" \
          -d postgres -q; do
    echo "[init-standby] Waiting for primary at ${PRIMARY_HOST}:${PRIMARY_PORT}..."
    sleep 2
  done

  echo "[init-standby] Primary ready. Running pg_basebackup..."
  # -R   write standby.signal + primary_conninfo into postgresql.auto.conf
  # -Xs  stream WAL during backup (consistent on completion)
  # -Fp  plain format (1:1 file layout)
  # -P   progress
  # -S   use named replication slot on primary
  # -C   create slot if it doesn't exist (idempotent)
  gosu postgres bash -c "PGPASSWORD='${REPLICATION_PASSWORD}' pg_basebackup \
    -h '${PRIMARY_HOST}' \
    -p '${PRIMARY_PORT}' \
    -U '${REPLICATION_USER}' \
    -D '${PGDATA}' \
    -Fp -Xs -P -R \
    -S '${REPLICATION_SLOT}' \
    -v"

  # pg_basebackup -R writes primary_conninfo into postgresql.auto.conf
  # We don't need to do anything else - postgresql.auto.conf is always
  # loaded last and overrides whatever is in postgresql.conf.

  echo "[init-standby] Base backup complete. Starting postgres as standby."
else
  echo "[init-standby] Data dir already initialized. Starting normally."
fi

# Hand off to the standard postgres entrypoint
exec docker-entrypoint.sh "$@"
