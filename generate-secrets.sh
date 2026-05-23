#!/bin/sh
# Generates random passwords for all four roles into ./secrets/*.txt with mode 0600.
# Safe to re-run only if all secret files have been removed (it refuses to overwrite).
set -eu

SECRETS_DIR="$(dirname "$0")/secrets"
mkdir -p "$SECRETS_DIR"
chmod 0700 "$SECRETS_DIR"
cd "$SECRETS_DIR"

# LC_ALL=C: macOS `tr` is locale-aware and rejects non-UTF-8 bytes from
# /dev/urandom with "Illegal byte sequence", producing empty output.
gen() { LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32; }

for name in postgres replication readonly pgbouncer_auth; do
  file="${name}_password.txt"
  if [ -f "$file" ]; then
    echo "REFUSING to overwrite existing $file (delete it first if you really want to rotate)."
    exit 1
  fi
  gen > "$file"
  chmod 0600 "$file"
  echo "Wrote $file ($(wc -c < "$file") bytes, mode 0600)"
done

echo
echo "Done. .env.example -> .env still needs to be done separately."
