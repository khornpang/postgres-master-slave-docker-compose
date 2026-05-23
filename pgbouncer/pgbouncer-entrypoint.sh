#!/bin/sh
# Render /etc/pgbouncer/pgbouncer.ini from its template at container start:
#   1. Generate one writes (<db>) + one reads (<db>_ro) pool per entry in
#      POSTGRES_DBS, pointing at postgres-primary / postgres-standby on
#      POSTGRES_PORT.
#   2. Replace the `; __PGB_DATABASES__` marker line in the template with
#      the generated pool block.
#   3. Substitute ${PGBOUNCER_AUTH_USER} and ${PGBOUNCER_PORT} wherever
#      they appear.
# Then hand off to the upstream edoburu/pgbouncer entrypoint, which builds
# userlist.txt from DB_USER + DB_PASSWORD and execs pgbouncer. Note: the
# upstream script does NOT support DB_PASSWORD_FILE, so we read the file
# into DB_PASSWORD ourselves below.
set -eu

: "${POSTGRES_DBS:=monitor}"
: "${POSTGRES_PORT:=5432}"
: "${PGBOUNCER_PORT:=6432}"
: "${PGBOUNCER_AUTH_USER:=pgbouncer}"

TEMPLATE=/etc/pgbouncer/pgbouncer.ini.template
TARGET=/etc/pgbouncer/pgbouncer.ini
DB_BLOCK=$(mktemp)
trap 'rm -f "$DB_BLOCK"' EXIT

if [ ! -r "$TEMPLATE" ]; then
  echo "[pgbouncer-entrypoint] ERROR: template not found at $TEMPLATE" >&2
  exit 1
fi

# Build the [databases] block. Pad pool names to 16 chars so the rendered
# file lines up; that's cosmetic, pgbouncer doesn't care about whitespace.
old_IFS=$IFS
IFS=,
for raw in $POSTGRES_DBS; do
  db=$(printf '%s' "$raw" | tr -d '[:space:]')
  [ -z "$db" ] && continue
  printf '%-16s = host=postgres-primary port=%s dbname=%s auth_user=%s\n' \
    "$db"      "$POSTGRES_PORT" "$db" "$PGBOUNCER_AUTH_USER" >> "$DB_BLOCK"
  printf '%-16s = host=postgres-standby port=%s dbname=%s auth_user=%s\n' \
    "${db}_ro" "$POSTGRES_PORT" "$db" "$PGBOUNCER_AUTH_USER" >> "$DB_BLOCK"
done
IFS=$old_IFS

if [ ! -s "$DB_BLOCK" ]; then
  echo "[pgbouncer-entrypoint] ERROR: POSTGRES_DBS produced no pool entries (got: '$POSTGRES_DBS')" >&2
  exit 1
fi

echo "[pgbouncer-entrypoint] Rendering $TARGET"
echo "[pgbouncer-entrypoint]   POSTGRES_DBS=$POSTGRES_DBS"
echo "[pgbouncer-entrypoint]   POSTGRES_PORT=$POSTGRES_PORT"
echo "[pgbouncer-entrypoint]   PGBOUNCER_PORT=$PGBOUNCER_PORT"
echo "[pgbouncer-entrypoint]   PGBOUNCER_AUTH_USER=$PGBOUNCER_AUTH_USER"

# Upstream entrypoint reads DB_PASSWORD (plain env var) to write userlist.txt
# but doesn't support DB_PASSWORD_FILE. Load the file ourselves so auth_query
# works.
if [ -z "${DB_PASSWORD:-}" ] && [ -n "${DB_PASSWORD_FILE:-}" ] && [ -r "$DB_PASSWORD_FILE" ]; then
  DB_PASSWORD=$(tr -d '\n\r' < "$DB_PASSWORD_FILE")
  export DB_PASSWORD
  echo "[pgbouncer-entrypoint] Loaded DB_PASSWORD from $DB_PASSWORD_FILE"
fi

# awk substitution: inject the [databases] block at the marker line, and
# replace ${PGBOUNCER_AUTH_USER} / ${PGBOUNCER_PORT} on every other line.
# Using index/substr instead of gsub so the placeholder text isn't
# interpreted as a regex.
awk -v dbsfile="$DB_BLOCK" -v auth="$PGBOUNCER_AUTH_USER" -v port="$PGBOUNCER_PORT" '
  function subst(line, needle, value,    p) {
    while ((p = index(line, needle)) > 0) {
      line = substr(line, 1, p - 1) value substr(line, p + length(needle))
    }
    return line
  }
  /^; __PGB_DATABASES__$/ {
    while ((getline line < dbsfile) > 0) print line
    close(dbsfile)
    next
  }
  {
    line = subst($0,   "${PGBOUNCER_AUTH_USER}", auth)
    line = subst(line, "${PGBOUNCER_PORT}",      port)
    print line
  }
' "$TEMPLATE" > "$TARGET"

exec /entrypoint.sh "$@"
