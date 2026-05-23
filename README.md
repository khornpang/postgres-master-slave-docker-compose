# Production Postgres: Primary + Standby + PgBouncer + Backups

Hardened setup for a NestJS + Prisma application. Streaming replication
(async), connection pooling via PgBouncer, daily compressed base backups,
continuous WAL archiving for point-in-time recovery, restricted network
access, secrets out of env vars.

## Architecture

```
┌───────────────────┐        WAL stream         ┌───────────────────┐
│  postgres-primary │──────────────────────────▶│ postgres-standby  │
│    172.28.0.10    │      (replication slot)   │    172.28.0.11    │
│      writes       │                            │  reads / reports  │
└────────┬──────────┘                            └────────┬──────────┘
         │ WAL archive                                    │
         ▼                                                │
   wal_archive vol                                        │
         │                                                │
         ▼                                                │
┌───────────────────┐                                     │
│  postgres-backup  │  daily pg_basebackup, WAL cleanup   │
└───────────────────┘                                     │
                                                          │
                  ┌───────────────────┐                   │
   App ──────────▶│     pgbouncer     │───────────────────┘
   (127.0.0.1     │    172.28.0.20    │   per <db> in POSTGRES_DBS:
    :6432)        │                   │     <db>     -> primary
                  └───────────────────┘     <db>_ro  -> standby
```

## Roles

| Role             | Created by     | Purpose                                  |
| ---------------- | -------------- | ---------------------------------------- |
| `app`            | initdb         | Owner. Prisma migrations + writes.       |
| `replicator`     | init-primary   | Standby + backup container use it.       |
| `app_readonly`   | init-primary   | Prisma replica reads (reports).          |
| `pgbouncer`      | init-primary   | PgBouncer's auth_query lookup user.      |

## First-time setup

```bash
# 1. Generate strong passwords for all four roles.
#    Listing scripts explicitly so zsh doesn't trip on no-match globs.
chmod +x \
  generate-secrets.sh \
  test-setup.sh \
  init/init-primary.sh \
  init/init-standby.sh \
  init/primary-entrypoint.sh \
  backup/backup.sh \
  backup/entrypoint.sh \
  pgbouncer/pgbouncer-entrypoint.sh
./generate-secrets.sh

# 2. Copy env template, then edit if you need to change defaults
#    (POSTGRES_DBS, POSTGRES_PORT, etc.). The .env file holds no secrets;
#    secrets live in ./secrets/*.txt (gitignored).
cp .env.example .env

# 3. Bring it up
docker compose up -d

# 4. Watch the standby do its base backup (first start only)
docker compose logs -f postgres-standby

# 5. Verify replication, PgBouncer routing, and WAL archiving
./test-setup.sh
```

The standby's first start takes ~30-60s longer than the primary because
it waits for the primary to be healthy and then runs `pg_basebackup`.
`test-setup.sh` waits up to 5 minutes for all services to report healthy
before running its checks.

If anything fails during this first bring-up, see
[TROUBLESHOOTING.md](TROUBLESHOOTING.md) — it catalogs the gotchas we
hit (macOS `tr` locale, edoburu's missing `DB_PASSWORD_FILE` support,
named-volume permissions, `entrypoint:` resetting `CMD`, etc.).

## Verify everything is working

### Automated smoke test

`test-setup.sh` runs all the checks below in one shot and exits non-zero
on any failure. It reads `POSTGRES_DB` / `POSTGRES_USER` / `POSTGRES_PORT`
from `.env` and passwords from `secrets/`, so it tracks your config.

```bash
./test-setup.sh
```

The script waits up to 5 minutes for primary, standby, and pgbouncer to
report `healthy`, then runs steps A–E below. Use it as a post-deploy gate
or after rebuilding the standby.

### Manual checks

The commands below use the defaults from `.env.example`
(`POSTGRES_DBS=monitor,logger`, `POSTGRES_PORT=5432`). If you changed either,
substitute your values — for any database `<db>` in `POSTGRES_DBS`, the
read-only pool is named `<db>_ro`. PgBouncer's pool names, upstream `port`,
and the postgres listen port are all rendered at container start, so they
always track what's in `.env`.

```bash
# A) Replication is streaming
docker exec -it postgres-primary psql -U app -d monitor -c "
  SELECT application_name, client_addr, state, sync_state,
         pg_size_pretty(pg_wal_lsn_diff(sent_lsn, replay_lsn)) AS lag_bytes
  FROM pg_stat_replication;"
# Expect: one row, state=streaming

# B) Standby is in recovery and current
docker exec -it postgres-standby psql -U app -d monitor -c "
  SELECT pg_is_in_recovery() AS is_replica,
         now() - pg_last_xact_replay_timestamp() AS lag;"
# Expect: t, lag < 1s

# C) End-to-end write -> read
docker exec -it postgres-primary psql -U app -d monitor \
  -c "CREATE TABLE _smoke (id int); INSERT INTO _smoke VALUES (1);"
sleep 1
docker exec -it postgres-standby psql -U app -d monitor -c "SELECT * FROM _smoke;"
# Expect: 1
docker exec -it postgres-standby psql -U app -d monitor -c "INSERT INTO _smoke VALUES (2);"
# Expect: ERROR cannot execute INSERT in a read-only transaction

# D) PgBouncer routes correctly (one pair per <db> in POSTGRES_DBS)
PG_PASS=$(cat secrets/postgres_password.txt)
RO_PASS=$(cat secrets/readonly_password.txt)
PGPASSWORD="$PG_PASS"   psql "host=127.0.0.1 port=6432 user=app          dbname=monitor"    -c "SELECT 'monitor via pgbouncer -> primary';"
PGPASSWORD="$RO_PASS"   psql "host=127.0.0.1 port=6432 user=app_readonly dbname=monitor_ro" -c "SELECT 'monitor via pgbouncer -> standby';"
PGPASSWORD="$PG_PASS"   psql "host=127.0.0.1 port=6432 user=app          dbname=logger"     -c "SELECT 'logger via pgbouncer -> primary';"
PGPASSWORD="$RO_PASS"   psql "host=127.0.0.1 port=6432 user=app_readonly dbname=logger_ro"  -c "SELECT 'logger via pgbouncer -> standby';"

# E) WAL archiving is happening
docker exec -it postgres-primary ls -la /var/lib/postgresql/archive/ | head
# Expect: WAL filenames like 000000010000000000000003 piling up
```

## Prisma configuration

`.env` of your NestJS app (point at PgBouncer, never directly at Postgres):

```env
# --- Primary application DB ('monitor') ---
# Writes + reads via pgbouncer transaction pool
DATABASE_URL="postgresql://app:<postgres_password>@host.docker.internal:6432/monitor?pgbouncer=true&connection_limit=20&schema=public"
# Read replica for reports / heavy queries
DATABASE_URL_REPLICA="postgresql://app_readonly:<readonly_password>@host.docker.internal:6432/monitor_ro?pgbouncer=true&connection_limit=20&schema=public"
# Migrations: bypass pgbouncer (Prisma migrate uses advisory locks that
# don't work in transaction pooling mode)
DIRECT_URL="postgresql://app:<postgres_password>@host.docker.internal:5432/monitor?schema=public"

# --- Secondary DB ('logger') ---
# Same shape, just a different dbname/pool. Add more pairs per entry in
# POSTGRES_DBS if you grow the list.
LOGGER_DATABASE_URL="postgresql://app:<postgres_password>@host.docker.internal:6432/logger?pgbouncer=true&connection_limit=20&schema=public"
LOGGER_DATABASE_URL_REPLICA="postgresql://app_readonly:<readonly_password>@host.docker.internal:6432/logger_ro?pgbouncer=true&connection_limit=20&schema=public"
LOGGER_DIRECT_URL="postgresql://app:<postgres_password>@host.docker.internal:5432/logger?schema=public"
```

Each Prisma schema (`prisma/schema.prisma`, `prisma/logger.prisma`, …) gets
its own `datasource db` block pointing at the matching pair of env vars.
Generate clients into separate output directories so they don't clobber
each other.

If your app runs on the same Docker host but outside the `pg-net` network,
`host.docker.internal` works on Mac/Windows; on Linux use the host IP or
join your app to `pg-net` and use `pgbouncer:6432`.

For `DIRECT_URL` to work, you'd need to publish the primary's 5432 port
to localhost. Either add `ports: ["127.0.0.1:5432:5432"]` to
postgres-primary, or run migrations from inside a container on `pg-net`.

`schema.prisma`:

```prisma
datasource db {
  provider  = "postgresql"
  url       = env("DATABASE_URL")
  directUrl = env("DIRECT_URL")
}
```

`PrismaService` with read-replica extension:

```ts
import { Injectable, OnModuleInit } from '@nestjs/common';
import { PrismaClient } from '@prisma/client';
import { readReplicas } from '@prisma/extension-read-replicas';

@Injectable()
export class PrismaService extends PrismaClient implements OnModuleInit {
  readonly withReplica = this.$extends(
    readReplicas({ url: process.env.DATABASE_URL_REPLICA! }),
  );

  async onModuleInit() {
    await this.$connect();
  }
}
```

`ReportingService`:

```ts
this.prisma.withReplica.$replica().post.groupBy({
  by: ['authorId', 'status'],
  where: { createdAt: { gte: start, lte: end } },
  _count: true,
});
```

## Operations runbook

### Monitor replication lag

```sql
-- on primary
SELECT application_name, client_addr,
       pg_size_pretty(pg_wal_lsn_diff(sent_lsn, replay_lsn)) AS bytes_behind,
       write_lag, flush_lag, replay_lag
FROM pg_stat_replication;
```

Expose this from a healthcheck endpoint. Alert if `replay_lag > 30s` for
more than a minute.

### Slow queries

`pg_stat_statements` is preloaded:

```sql
SELECT total_exec_time, calls, mean_exec_time, query
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT 20;
```

### Trigger a backup manually

```bash
docker compose exec postgres-backup /usr/local/bin/backup.sh
docker compose exec postgres-backup ls -lh /backups
```

### List backups and archive

```bash
docker run --rm -v postgres-production_backups:/b alpine ls -lh /b
docker run --rm -v postgres-production_wal_archive:/a alpine sh -c 'ls /a | wc -l; du -sh /a'
```

### Restore (PITR)

1. Stop the stack: `docker compose down`
2. Recreate `primary_data` volume empty.
3. Pick a backup: `base_<timestamp>/data.tar.gz`
4. Extract into the volume.
5. Set `recovery_target_time = '...'` in postgresql.auto.conf, or
   `recovery_target_xid = ...`
6. Make sure `restore_command` is set to copy from `/var/lib/postgresql/archive/%f`
7. Start primary, monitor logs. Postgres will replay WAL up to target.
8. After recovery, run `SELECT pg_promote();` and rebuild the standby
   (delete `standby_data` volume, `docker compose up -d` recreates it).

Full step-by-step is verbose - keep this runbook with your DR docs and
practice the restore on a non-prod copy every quarter.

### Failover (primary is dead, promote standby)

```bash
# 1. Confirm primary is really gone (don't split-brain)
docker compose ps postgres-primary

# 2. Promote standby - it becomes a normal read-write primary
docker exec -it postgres-standby psql -U app -d monitor -c "SELECT pg_promote(true, 60);"

# 3. Switch the app to point at the standby
#    Easiest: edit pgbouncer-entrypoint.sh so each <db> pool points at
#    postgres-standby (the promoted node) and each <db>_ro is removed or
#    repointed, then restart pgbouncer. The entrypoint re-renders
#    pgbouncer.ini from the template on every start.
docker compose restart pgbouncer

# 4. Rebuild what used to be the primary as the new standby:
docker compose down postgres-primary
docker volume rm postgres-production_primary_data
# Update compose so the OLD primary uses the standby init script and
# points at the NEW primary. Then:
docker compose up -d postgres-primary
```

Manual failover is fine for a reporting setup. If RTO matters more,
look at **Patroni** - but it's a much bigger commitment.

### Rotate a password

1. Generate new password.
2. `ALTER ROLE <role> PASSWORD '<new>';` on the primary.
3. Update `secrets/<role>_password.txt` with the new value.
4. Restart anything that uses that password
   (`docker compose restart pgbouncer` etc).

Because PgBouncer uses `auth_query`, it picks up new passwords without
restart for non-admin users - but a restart is the safe move.

### Where logs live

| What            | Inside container          | Volume              |
| --------------- | ------------------------- | ------------------- |
| Primary postgres| `/var/log/postgresql`     | `primary_logs`      |
| Standby postgres| `/var/log/postgresql`     | `standby_logs`      |
| Backup runs     | `/var/log/backup`         | `backup_logs`       |
| PgBouncer       | stdout                    | docker logs         |
| All containers  | stdout                    | docker logs (json)  |

Promtail can scrape both the volumes and the docker socket - your
existing Grafana/Loki setup will pick all of this up.

## Production hardening checklist

Things this setup handles:

- [x] Tuned `postgresql.conf` (memory, parallelism, WAL, autovacuum)
- [x] Restricted `pg_hba.conf` (Docker subnet only, no `0.0.0.0/0`)
- [x] SCRAM-SHA-256 with `--data-checksums`
- [x] Secrets as files via Docker secrets (not env vars)
- [x] Replication slot to prevent WAL gaps
- [x] `hot_standby_feedback` so long reports don't get cancelled
- [x] WAL archiving for PITR
- [x] Daily compressed base backups with retention
- [x] PgBouncer transaction pooling, Prisma-compatible
- [x] Resource limits (memory/CPU)
- [x] Persistent logs (volume + json-file with rotation)
- [x] `pg_stat_statements` preloaded
- [x] Defensive timeouts (`lock_timeout`, `idle_in_transaction_session_timeout`)
- [x] Healthchecks for all services
- [x] Bind PgBouncer to 127.0.0.1 only (no public exposure)

Things you should still do (out of scope here):

- [ ] **Offsite backup sync.** The `backups` volume is on the same host.
      Mount it on the host and rsync nightly to a different machine /
      bucket / NAS.
- [ ] **TLS for replication & client connections.** Generate certs,
      mount them, set `ssl = on` in postgresql.conf, add `hostssl`
      lines in pg_hba.conf, set `sslmode=require` in connection strings.
      Worth the effort if standby will ever live on a different host.
- [ ] **OS-level hardening.** Run on a non-root user, kernel huge pages,
      tuned IO scheduler, ulimits.
- [ ] **Monitoring.** Drop in `prometheuscommunity/postgres-exporter` if
      you decide to add Prometheus alongside Loki.
- [ ] **Automatic failover.** Patroni if you need it. Otherwise practice
      the manual procedure above quarterly.
- [ ] **Restore drill.** A backup you've never restored from is a backup
      you don't have. Schedule a quarterly test restore on a separate VM.

## Tuning for a different host size

The configs target an 8 GB / 4 vCPU host. If your host has a different
shape, adjust these in both `config/primary/postgresql.conf` and
`config/standby/postgresql.conf`:

| Setting             | Formula                                          |
| ------------------- | ------------------------------------------------ |
| shared_buffers      | 25% of RAM                                       |
| effective_cache_size| 75% of RAM                                       |
| work_mem            | (RAM - shared_buffers) / (max_connections * 3)   |
| maintenance_work_mem| RAM / 16, capped at 2 GB                         |
| max_worker_processes| ≈ vCPU count                                     |

Also bump `memory:` limits in `docker-compose.yml` accordingly.
