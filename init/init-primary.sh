#!/bin/bash
# Runs once on the FIRST start of the primary (empty data dir).
# Sets up: replication role, readonly role, pgbouncer auth role,
# replication slot, and per-database grants + pgbouncer auth_query function
# + pg_stat_statements extension for every database in POSTGRES_DBS.
set -euo pipefail

read_secret() { tr -d '\n\r' < "/run/secrets/$1"; }

REPLICATION_PASSWORD=$(read_secret replication_password)
READONLY_PASSWORD=$(read_secret readonly_password)
PGBOUNCER_AUTH_PASSWORD=$(read_secret pgbouncer_auth_password)

# POSTGRES_DBS is comma-separated. The first entry is the bootstrap DB
# already created by the postgres image (POSTGRES_DB == first entry,
# set by primary-entrypoint.sh).
: "${POSTGRES_DBS:=$POSTGRES_DB}"

echo "[init-primary] Roles + replication slot..."

# ============================================================
# Cluster-wide objects: roles + replication slot.
# Run against the bootstrap database — these are not database-scoped.
# ============================================================
psql -v ON_ERROR_STOP=1 \
     --username "$POSTGRES_USER" \
     --dbname "$POSTGRES_DB" <<-EOSQL
  -- Replication role (standby + backup container use it)
  CREATE ROLE ${REPLICATION_USER} WITH
    REPLICATION
    LOGIN
    ENCRYPTED PASSWORD '${REPLICATION_PASSWORD}';

  -- Read-only application role
  CREATE ROLE ${READONLY_USER} WITH
    LOGIN
    ENCRYPTED PASSWORD '${READONLY_PASSWORD}';

  -- PgBouncer auth_query role
  CREATE ROLE ${PGBOUNCER_AUTH_USER} WITH
    LOGIN
    ENCRYPTED PASSWORD '${PGBOUNCER_AUTH_PASSWORD}';

  -- Physical replication slot for the standby
  SELECT pg_create_physical_replication_slot('standby_slot');
EOSQL

# ============================================================
# Per-database setup. For each entry in POSTGRES_DBS:
#   1. CREATE DATABASE (skipped for the bootstrap DB)
#   2. Grants for the readonly role (must run *inside* that DB to
#      affect schema-level privileges and default privileges)
#   3. pgbouncer.user_lookup function (auth_query target — PgBouncer
#      runs it in whatever DB the pool is connected to, so it must
#      exist in every DB)
#   4. pg_stat_statements extension
# ============================================================
OLD_IFS="$IFS"; IFS=','
for raw in $POSTGRES_DBS; do
  db=$(printf '%s' "$raw" | tr -d '[:space:]')
  [ -z "$db" ] && continue

  if [ "$db" != "$POSTGRES_DB" ]; then
    echo "[init-primary] Creating database '$db'..."
    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
      -c "CREATE DATABASE \"$db\" OWNER \"$POSTGRES_USER\";"
  else
    echo "[init-primary] Database '$db' already created by image bootstrap."
  fi

  echo "[init-primary] Configuring '$db' (grants, pgbouncer auth, extensions)..."
  psql -v ON_ERROR_STOP=1 \
       --username "$POSTGRES_USER" \
       --dbname "$db" <<-EOSQL
    -- Readonly role grants
    GRANT CONNECT ON DATABASE "$db" TO ${READONLY_USER};
    GRANT USAGE ON SCHEMA public TO ${READONLY_USER};
    GRANT SELECT ON ALL TABLES IN SCHEMA public TO ${READONLY_USER};
    GRANT SELECT ON ALL SEQUENCES IN SCHEMA public TO ${READONLY_USER};

    -- Future tables/sequences created by the owner get SELECT automatically.
    ALTER DEFAULT PRIVILEGES FOR ROLE ${POSTGRES_USER} IN SCHEMA public
      GRANT SELECT ON TABLES TO ${READONLY_USER};
    ALTER DEFAULT PRIVILEGES FOR ROLE ${POSTGRES_USER} IN SCHEMA public
      GRANT SELECT ON SEQUENCES TO ${READONLY_USER};

    -- PgBouncer auth_query lookup function (SECURITY DEFINER so the
    -- pgbouncer role doesn't need direct read on pg_shadow).
    CREATE SCHEMA IF NOT EXISTS pgbouncer AUTHORIZATION ${POSTGRES_USER};

    CREATE OR REPLACE FUNCTION pgbouncer.user_lookup(
      IN  i_username text,
      OUT uname      text,
      OUT phash      text
    ) RETURNS record AS \$\$
    BEGIN
      SELECT usename, passwd FROM pg_catalog.pg_shadow
        WHERE usename = i_username INTO uname, phash;
      RETURN;
    END;
    \$\$ LANGUAGE plpgsql SECURITY DEFINER;

    REVOKE ALL ON FUNCTION pgbouncer.user_lookup(text) FROM public;
    GRANT  EXECUTE ON FUNCTION pgbouncer.user_lookup(text) TO ${PGBOUNCER_AUTH_USER};
    GRANT  USAGE ON SCHEMA pgbouncer TO ${PGBOUNCER_AUTH_USER};

    -- Extensions
    CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
EOSQL
done
IFS="$OLD_IFS"

echo "[init-primary] Ensuring archive directory exists with correct ownership..."
mkdir -p /var/lib/postgresql/archive
chown -R postgres:postgres /var/lib/postgresql/archive
chmod 0700 /var/lib/postgresql/archive

echo "[init-primary] Ensuring log directory exists with correct ownership..."
mkdir -p /var/log/postgresql
chown -R postgres:postgres /var/log/postgresql
chmod 0750 /var/log/postgresql

echo "[init-primary] Initialization complete."
