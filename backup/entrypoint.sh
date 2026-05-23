#!/bin/sh
# Backup container entrypoint. Installs the cron schedule and runs crond
# in the foreground.
set -eu

LOG_FILE="/var/log/backup/backup.log"
mkdir -p /var/log/backup
touch "$LOG_FILE"

echo "[entrypoint] Backup schedule: ${BACKUP_SCHEDULE}"
echo "[entrypoint] Retention: ${BACKUP_RETENTION_DAYS} days"
echo "[entrypoint] Primary: ${PRIMARY_HOST}:${PRIMARY_PORT}"

# Build crontab. Environment isn't inherited by cron jobs, so we pass it
# explicitly through `env`.
mkdir -p /etc/crontabs
cat > /etc/crontabs/root <<EOF
${BACKUP_SCHEDULE} env PRIMARY_HOST='${PRIMARY_HOST}' PRIMARY_PORT='${PRIMARY_PORT}' REPLICATION_USER='${REPLICATION_USER}' BACKUP_RETENTION_DAYS='${BACKUP_RETENTION_DAYS}' /usr/local/bin/backup.sh >> ${LOG_FILE} 2>&1
EOF

echo "[entrypoint] Installed crontab:"
cat /etc/crontabs/root

# Run an initial backup on startup if no backups exist yet
if [ -z "$(ls -A /backups 2>/dev/null)" ]; then
  echo "[entrypoint] No existing backups - taking initial backup now."
  /usr/local/bin/backup.sh >> "$LOG_FILE" 2>&1 || \
    echo "[entrypoint] WARNING: initial backup failed (will retry on next schedule)."
fi

echo "[entrypoint] Starting crond (logs streamed to stdout + ${LOG_FILE})."
# -f foreground, -d 8 = info level
exec crond -f -d 8
