#!/bin/sh
# Daily base backup + WAL archive cleanup.
# Designed to run from cron inside the backup container.
set -eu

BACKUP_DIR="/backups"
ARCHIVE_DIR="/var/lib/postgresql/archive"
RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-7}"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
NEW_BACKUP="$BACKUP_DIR/base_$TIMESTAMP"
LOG_PREFIX="[backup $(date -Iseconds)]"

PGPASSWORD="$(tr -d '\n\r' < /run/secrets/replication_password)"
export PGPASSWORD

echo "$LOG_PREFIX Starting base backup -> $NEW_BACKUP"
mkdir -p "$NEW_BACKUP"

# -Fp  : plain format (browsable, easy to restore)
# -Xs  : stream WAL alongside backup (self-consistent)
# -P   : progress
# -c fast : checkpoint immediately rather than waiting for next natural one
# -l   : label
if ! pg_basebackup \
      -h "$PRIMARY_HOST" \
      -p "$PRIMARY_PORT" \
      -U "$REPLICATION_USER" \
      -D "$NEW_BACKUP/data" \
      -Fp -Xs -P \
      -c fast \
      -l "scheduled_$TIMESTAMP"; then
  echo "$LOG_PREFIX ERROR: pg_basebackup failed. Removing partial backup."
  rm -rf "$NEW_BACKUP"
  exit 1
fi

# Compress to save space (typically 5-10x reduction)
echo "$LOG_PREFIX Compressing backup..."
tar -C "$NEW_BACKUP" -czf "$NEW_BACKUP/data.tar.gz" data
rm -rf "$NEW_BACKUP/data"
echo "$TIMESTAMP" > "$NEW_BACKUP/timestamp"
du -sh "$NEW_BACKUP"

echo "$LOG_PREFIX Base backup complete."

# -------------------------------------------------------------------
# Cleanup: remove base backups older than retention
# -------------------------------------------------------------------
echo "$LOG_PREFIX Cleaning base backups older than $RETENTION_DAYS days..."
find "$BACKUP_DIR" -maxdepth 1 -type d -name "base_*" -mtime "+$RETENTION_DAYS" \
     -exec sh -c 'echo "  deleting $1"; rm -rf "$1"' _ {} \;

# -------------------------------------------------------------------
# WAL archive cleanup: anything older than (retention + 1) days is gone.
# Conservative - if you need stricter PITR, increase BACKUP_RETENTION_DAYS.
# -------------------------------------------------------------------
WAL_RETENTION=$((RETENTION_DAYS + 1))
echo "$LOG_PREFIX Cleaning WAL files older than $WAL_RETENTION days..."
WAL_DELETED=$(find "$ARCHIVE_DIR" -type f -mtime "+$WAL_RETENTION" -delete -print | wc -l)
echo "$LOG_PREFIX Removed $WAL_DELETED old WAL segments."

# -------------------------------------------------------------------
# Summary
# -------------------------------------------------------------------
echo "$LOG_PREFIX === Backup summary ==="
ls -lh "$BACKUP_DIR" | head -50
echo "$LOG_PREFIX Archive dir size: $(du -sh "$ARCHIVE_DIR" | cut -f1)"
echo "$LOG_PREFIX Done."
