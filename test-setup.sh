#!/usr/bin/env bash
# Smoke-test the stack after `docker compose up -d`.
# Run from the project root (same directory as docker-compose.yml + .env).
# All names/ports are read from .env so the script tracks your config.
set -uo pipefail

# ── Load .env ────────────────────────────────────────────────────────
if [ ! -f .env ]; then
  echo "ERROR: .env not found. Run from the project root (where docker-compose.yml lives)." >&2
  exit 1
fi
set -a
# shellcheck disable=SC1091
. ./.env
set +a

POSTGRES_USER="${POSTGRES_USER:-app}"
POSTGRES_DBS="${POSTGRES_DBS:-monitor}"
POSTGRES_PORT="${POSTGRES_PORT:-5432}"
READONLY_USER="${READONLY_USER:-app_readonly}"

# Split POSTGRES_DBS into an array; first entry is the bootstrap DB used
# for cluster-wide tests (replication, WAL archive). Test D iterates all.
IFS=',' read -ra DB_LIST <<< "$POSTGRES_DBS"
for i in "${!DB_LIST[@]}"; do
  DB_LIST[$i]="${DB_LIST[$i]//[[:space:]]/}"
done
POSTGRES_DB="${DB_LIST[0]}"

# ── Read secrets ─────────────────────────────────────────────────────
if [ ! -d secrets ]; then
  echo "ERROR: secrets/ directory not found. Did you run ./generate-secrets.sh?" >&2
  exit 1
fi
PG_PASS="$(tr -d '\n\r' < secrets/postgres_password.txt)"
RO_PASS="$(tr -d '\n\r' < secrets/readonly_password.txt)"

# ── Output helpers ───────────────────────────────────────────────────
if [ -t 1 ]; then
  RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
else
  RED=; GREEN=; YELLOW=; BOLD=; RESET=
fi
PASS=0; FAIL=0
pass()   { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$1"; PASS=$((PASS+1)); }
fail()   { printf '  %s✗%s %s\n' "$RED"   "$RESET" "$1" >&2; FAIL=$((FAIL+1)); }
info()   { printf '  %s·%s %s\n' "$YELLOW" "$RESET" "$1"; }
header() { printf '\n%s[%s] %s%s\n' "$BOLD" "$1" "$2" "$RESET"; }

# psql against a service using POSTGRES_USER / POSTGRES_DB. Pass PGPASSWORD
# through `exec -e` since auth_local=scram-sha-256 means even socket
# connections need a password.
psql_on() {
  local service=$1; shift
  docker compose exec -T -e PGPASSWORD="$PG_PASS" "$service" \
    psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tA -v ON_ERROR_STOP=1 "$@"
}

printf '%s== Postgres stack smoke test ==%s\n' "$BOLD" "$RESET"
printf '   POSTGRES_DBS=%s   POSTGRES_USER=%s   POSTGRES_PORT=%s\n' \
  "$POSTGRES_DBS" "$POSTGRES_USER" "$POSTGRES_PORT"
printf '   bootstrap DB = %s (used for replication tests)\n' "$POSTGRES_DB"

# ── Preflight: wait for services to be healthy ───────────────────────
header preflight "Waiting for primary, standby, pgbouncer to be healthy (≤5 min)"
deadline=$(( $(date +%s) + 300 ))
while :; do
  ph=$(docker inspect --format '{{.State.Health.Status}}' postgres-primary 2>/dev/null || echo missing)
  sh=$(docker inspect --format '{{.State.Health.Status}}' postgres-standby 2>/dev/null || echo missing)
  bh=$(docker inspect --format '{{.State.Health.Status}}' pgbouncer        2>/dev/null || echo missing)
  if [ "$ph" = healthy ] && [ "$sh" = healthy ] && [ "$bh" = healthy ]; then
    pass "primary=$ph  standby=$sh  pgbouncer=$bh"
    break
  fi
  if [ "$(date +%s)" -ge "$deadline" ]; then
    fail "still not healthy: primary=$ph standby=$sh pgbouncer=$bh"
    exit 1
  fi
  info "  primary=$ph standby=$sh pgbouncer=$bh — sleeping 5s"
  sleep 5
done

# ── A: replication is streaming ──────────────────────────────────────
header A "Primary sees a streaming standby"
a_state=$(psql_on postgres-primary -c "SELECT state FROM pg_stat_replication LIMIT 1;" 2>&1 | tr -d '[:space:]')
if [ "$a_state" = "streaming" ]; then
  pass "pg_stat_replication.state = streaming"
else
  fail "expected 'streaming'; got '$a_state'"
fi

# ── B: standby is in recovery, lag is small ──────────────────────────
header B "Standby in recovery, replay lag bounded"
b_recovery=$(psql_on postgres-standby -c "SELECT pg_is_in_recovery();" 2>&1 | tr -d '[:space:]')
if [ "$b_recovery" = "t" ]; then
  pass "pg_is_in_recovery() = t"
else
  fail "expected 't'; got '$b_recovery'"
fi
b_lag=$(psql_on postgres-standby -c \
  "SELECT COALESCE(EXTRACT(EPOCH FROM (now() - pg_last_xact_replay_timestamp()))::int, 0);" \
  2>&1 | tr -d '[:space:]')
info "replay lag ≈ ${b_lag}s"

# ── C: end-to-end write → read; standby refuses writes ───────────────
header C "Write on primary, read on standby; writes blocked on standby"
SMOKE_VAL=$RANDOM
if psql_on postgres-primary -c \
     "CREATE TABLE IF NOT EXISTS _smoke (id int); INSERT INTO _smoke VALUES ($SMOKE_VAL);" \
     >/dev/null 2>&1; then
  pass "primary accepted insert id=$SMOKE_VAL"
else
  fail "primary insert failed"
fi
sleep 1
c_count=$(psql_on postgres-standby -c "SELECT count(*) FROM _smoke WHERE id = $SMOKE_VAL;" 2>&1 | tr -d '[:space:]')
if [ "$c_count" = "1" ]; then
  pass "standby returned 1 row for id=$SMOKE_VAL (replication working)"
else
  fail "expected count=1 on standby; got '$c_count'"
fi
c_ro=$(psql_on postgres-standby -c "INSERT INTO _smoke VALUES (-1);" 2>&1)
if printf '%s' "$c_ro" | grep -qi 'read-only'; then
  pass "standby correctly rejected INSERT"
else
  fail "expected read-only error on standby; got: $c_ro"
fi

# ── D: PgBouncer routes each pool to the correct backend ─────────────
header D "PgBouncer pool routing for each database in POSTGRES_DBS"
# Connect from the primary container into pgbouncer (both on pg-net).
# pgbouncer hostname resolves via Docker DNS; auth_query lets the
# app/app_readonly logins authenticate without entries in userlist.txt.
for db in "${DB_LIST[@]}"; do
  [ -z "$db" ] && continue
  ro_db="${db}_ro"

  d_writes=$(docker compose exec -T -e PGPASSWORD="$PG_PASS" postgres-primary \
    psql -h pgbouncer -p 6432 -U "$POSTGRES_USER" -d "$db" -tA -v ON_ERROR_STOP=1 \
    -c "SELECT pg_is_in_recovery();" 2>&1 | tr -d '[:space:]')
  if [ "$d_writes" = "f" ]; then
    pass "pool '$db' lands on primary (recovery=f)"
  else
    fail "pool '$db' expected primary (f); got '$d_writes'"
  fi

  d_reads=$(docker compose exec -T -e PGPASSWORD="$RO_PASS" postgres-primary \
    psql -h pgbouncer -p 6432 -U "$READONLY_USER" -d "$ro_db" -tA -v ON_ERROR_STOP=1 \
    -c "SELECT pg_is_in_recovery();" 2>&1 | tr -d '[:space:]')
  if [ "$d_reads" = "t" ]; then
    pass "pool '$ro_db' lands on standby (recovery=t)"
  else
    fail "pool '$ro_db' expected standby (t); got '$d_reads'"
  fi
done

# ── E: WAL archiving is happening ────────────────────────────────────
header E "WAL archive populating"
# Force a WAL switch so we always see at least one archived segment.
psql_on postgres-primary -c "SELECT pg_switch_wal();" >/dev/null 2>&1 || true
sleep 2
e_count=$(docker compose exec -T postgres-primary \
  sh -c 'ls -1 /var/lib/postgresql/archive 2>/dev/null | wc -l' | tr -d '[:space:]')
if [ "${e_count:-0}" -gt 0 ]; then
  pass "$e_count file(s) in /var/lib/postgresql/archive"
else
  fail "no WAL segments archived yet"
fi

# ── cleanup ──────────────────────────────────────────────────────────
psql_on postgres-primary -c "DROP TABLE IF EXISTS _smoke;" >/dev/null 2>&1 || true

# ── summary ──────────────────────────────────────────────────────────
printf '\n%s== %d passed, %d failed ==%s\n' \
  "$BOLD" "$PASS" "$FAIL" "$RESET"
[ "$FAIL" -eq 0 ]
