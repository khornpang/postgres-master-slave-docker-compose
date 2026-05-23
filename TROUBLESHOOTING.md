# Troubleshooting

Symptoms we actually hit during initial bring-up, with the fix or the
explanation of what's already handled in the code. Search by error message.

---

## During `./generate-secrets.sh`

### `cd: ./secrets: No such file or directory`
**Cause:** Older versions of the script didn't create the directory.
**Status:** Fixed — the script now `mkdir -p`s `./secrets` with mode 0700.

### `tr: Illegal byte sequence` (macOS) — empty password files
**Cause:** macOS `tr` is locale-aware (UTF-8) and rejects raw bytes from
`/dev/urandom`. The script appears to succeed but writes 0-byte files;
the next step fails far away with confusing auth errors.
**Status:** Fixed — `LC_ALL=C tr -dc ...` in the script.
**Recovery if you hit it on an older copy:** delete the empty files and
re-run: `rm secrets/*_password.txt && ./generate-secrets.sh`.

---

## During `docker compose up -d`

### `invalid mount config for type "bind": stat /host_mnt/.../secrets/<file>: operation not permitted`
**Cause:** Stale compose state — happens when a previous run failed
mid-way and left orphan mount references. Not a real permission problem.
**Fix:** `docker compose down -v && docker compose up -d`.
**Note:** This is *not* caused by the macOS `com.apple.provenance` xattr
on files in `~/Documents/`. That xattr is sticky (you can't remove it),
but Docker bind-mounts work fine alongside it once the stale state is
cleared.

### `postgres-primary` unhealthy, logs show `FATAL: could not open log file "/var/log/postgresql/...": Permission denied`
**Cause:** The named volume mounted at `/var/log/postgresql` is created
by Docker as `root:root` mode 755. Postgres runs as the `postgres` user
(uid 70) and can't write there. This blocks initdb's temporary server
startup, so `init-primary.sh` never runs and you'll also see a second
symptom: `PostgreSQL Database directory appears to contain a database;
Skipping initialization` on the next loop iteration.
**Status:** Fixed — `init/primary-entrypoint.sh` chowns
`/var/log/postgresql` and `/var/lib/postgresql/archive` before exec'ing
`docker-entrypoint.sh`. `init/init-standby.sh` does the same.
**Recovery if upgrading from an older copy:** the partially-initialized
volume must be wiped because postgres now refuses to re-init:
```
docker compose down -v
docker compose up -d
```

### `pgbouncer` in restart loop, logs end at `Wrote authentication credentials to /etc/pgbouncer/userlist.txt` then exit
**Cause:** Setting `entrypoint:` in compose **resets** the image's
default `CMD`. The upstream `/entrypoint.sh` ends with `exec "$@"`, gets
no args, and the container exits cleanly with code 0.
**Status:** Fixed — `docker-compose.yml` sets both `entrypoint:` and
`command: ["/usr/bin/pgbouncer", "/etc/pgbouncer/pgbouncer.ini"]` for
the pgbouncer service.

### `pgbouncer` reports `unhealthy` even though it's listening on `:6432`
**Cause:** BusyBox `nc -z localhost 6432` resolves `localhost` to IPv6
`::1`, but pgbouncer listens on `0.0.0.0` (IPv4 only).
**Status:** Fixed — healthcheck uses `nc -z 127.0.0.1 6432`.

### `password authentication failed for user "pgbouncer"` repeating in pgbouncer logs; `userlist.txt` is empty
**Cause:** The edoburu/pgbouncer image's entrypoint generates
`userlist.txt` from `DB_USER` + `DB_PASSWORD` (plain env vars). It does
**not** support `DB_PASSWORD_FILE` despite the Docker secrets pattern
being common. With only `DB_PASSWORD_FILE` set, `userlist.txt` stays
empty → every auth_query lookup fails.
**Status:** Fixed — `pgbouncer/pgbouncer-entrypoint.sh` reads the secret
file and exports `DB_PASSWORD` before chaining to the upstream entrypoint.

---

## During `./test-setup.sh`

### `./.env: line N: 2: command not found`
**Cause:** Unquoted values with spaces in `.env` (the cron schedule).
docker-compose's `.env` parser tolerates this; `. ./.env` in a shell
does not.
**Status:** Fixed in `.env.example` — `BACKUP_SCHEDULE="0 2 * * *"`.
**Fix if your local `.env` was copied before this fix:** quote any value
that contains a space.

### `fe_sendauth: no password supplied` from psql inside a container
**Cause:** `POSTGRES_INITDB_ARGS=--auth-local=scram-sha-256` requires a
password even on the unix socket. `docker compose exec ... psql ...`
doesn't inherit a password — it has to be passed explicitly.
**Status:** Fixed — `test-setup.sh`'s `psql_on` helper passes
`-e PGPASSWORD="$PG_PASS"` to `docker compose exec`. Use the same
pattern in any script you write.

---

## Resetting to a clean state

If anything above leaves the stack in an inconsistent state, the
nuclear option is safe **before** real data is in the DB:

```
docker compose down -v   # -v removes named volumes (data, logs, archive, backups)
docker compose up -d
./test-setup.sh
```

After production traffic starts, **never** run `down -v` — take a
backup first, then restore.

---

## Things to check before opening a bug

```
docker compose ps                              # all containers up?
docker compose logs postgres-primary | tail    # primary really started?
docker compose exec -T pgbouncer cat /etc/pgbouncer/userlist.txt   # not empty?
docker compose exec -T pgbouncer cat /etc/pgbouncer/pgbouncer.ini  # pools rendered?
docker compose config -q                       # compose file valid?
```
