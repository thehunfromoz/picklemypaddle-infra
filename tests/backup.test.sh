#!/usr/bin/env bash
# Test for the nightly backup (SCRUM-64), run in CI on a throwaway Docker host:
#   1. a backup writes a pg_dump and a photo archive into the backup folder, root-only;
#   2. the dump restores into a scratch database with the same row count;
#   3. the photo archive holds the photo files;
#   4. backups older than 30 days are deleted (faked dates), newer ones kept;
#   5. the log has counts and sizes, never the database password;
#   6. with postgres not running (production before orders open) it does nothing and succeeds.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
export STACK_DIR="$WORK/stack" BACKUP_DIR="$WORK/backups" BACKUP_KEEP_DAYS=30
PASSWORD="$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
compose() { docker compose --project-directory "$STACK_DIR" -f "$STACK_DIR/compose.test.yml" "$@"; }

pass() { printf '\033[32mPASS\033[0m %s\n' "$*"; }
die() {
  printf '\033[31mFAIL\033[0m %s\n' "$*" >&2
  [[ -n "${GITHUB_ACTIONS:-}" ]] && echo "::error title=backup test::$*"
  exit 1
}
cleanup() { compose down -v >/dev/null 2>&1 || true; rm -rf "$WORK"; }
trap cleanup EXIT
trap 'die "unexpected failure at line $LINENO"' ERR

mkdir -p "$STACK_DIR"
cp "$ROOT/staging/backup.sh" "$STACK_DIR/"
# The same postgres service and volume names as the real stacks, minus everything else.
cat >"$STACK_DIR/compose.test.yml" <<YAML
name: pmp-backup-test
services:
  postgres:
    image: postgres:18-alpine
    environment: { POSTGRES_USER: pmp, POSTGRES_DB: pmp, POSTGRES_PASSWORD: "$PASSWORD" }
    volumes: [pgdata:/var/lib/postgresql]
    healthcheck: { test: ["CMD-SHELL", "pg_isready -U pmp -d pmp -h 127.0.0.1"], interval: 2s, retries: 30 }
  # Stands in for integrations, which mounts the photo volume in the real stacks. Never started;
  # it's here because Compose leaves volumes no service uses out of \`docker compose config\`.
  integrations:
    image: postgres:18-alpine
    entrypoint: ["true"]
    volumes: [photos:/data/photos]
volumes:
  pgdata: { name: pmp-backup-test-pgdata }
  photos: { name: pmp-backup-test-photos }
YAML

# 6 first: nothing running yet.
out="$("$STACK_DIR/backup.sh" 2>&1)" || die "backup.sh should succeed when postgres isn't running: $out"
grep -q "nothing to back up" <<<"$out" || die "expected 'nothing to back up', got: $out"
[[ ! -e "$BACKUP_DIR" ]] || die "nothing should be written when postgres isn't running"
pass "6. postgres not running: nothing to back up, exit 0"

compose up -d --wait postgres >/dev/null 2>&1 || die "test postgres didn't start"
psql() { compose exec -T postgres psql -U pmp -d "$1" -tAqc "$2"; }
psql pmp "CREATE TABLE orders (id serial PRIMARY KEY, reference text); INSERT INTO orders (reference) SELECT 'PMP-' || g FROM generate_series(1, 37) g;"
docker volume create pmp-backup-test-photos >/dev/null
docker run --rm -v pmp-backup-test-photos:/p postgres:18-alpine sh -c 'mkdir -p /p/ab && echo jpeg-bytes > /p/ab/abcdef.jpg'

# Old backups to prune: 31 and 45 days old go, 29 days old stays.
mkdir -p "$BACKUP_DIR"
for age in 31 45 29; do
  touch -d "$age days ago" "$BACKUP_DIR/db-old$age.dump" "$BACKUP_DIR/photos-old$age.tar.gz"
done
touch -d "60 days ago" "$BACKUP_DIR/unrelated.txt"

out="$("$STACK_DIR/backup.sh" 2>&1)" || die "backup failed: $out"
echo "$out"
dump="$(find "$BACKUP_DIR" -name 'db-2*.dump')"
archive="$(find "$BACKUP_DIR" -name 'photos-2*.tar.gz')"
[[ -s "$dump" && -s "$archive" ]] || die "expected a new dump and photo archive in $BACKUP_DIR"
[[ "$(stat -c '%a' "$BACKUP_DIR")" == 700 ]] || die "backup folder should be 700, is $(stat -c '%a' "$BACKUP_DIR")"
[[ "$(stat -c '%a' "$dump")" == 600 ]] || die "dump should be 600, is $(stat -c '%a' "$dump")"
[[ -z "$(find "$BACKUP_DIR" -name '*.part')" ]] || die "a .part file was left behind"
pass "1. backup wrote a dump and a photo archive, root-only"

psql pmp "CREATE DATABASE scratch" >/dev/null
compose exec -T postgres pg_restore -U pmp -d scratch --no-owner <"$dump"
[[ "$(psql scratch 'SELECT count(*) FROM orders')" == 37 ]] || die "restored row count differs"
pass "2. the dump restores into a scratch database with all 37 rows"

tar -tzf "$archive" | grep -q 'ab/abcdef.jpg' || die "photo archive doesn't contain the photo"
pass "3. the photo archive holds the photo files"

for f in db-old31.dump photos-old31.tar.gz db-old45.dump photos-old45.tar.gz; do
  [[ ! -e "$BACKUP_DIR/$f" ]] || die "$f is older than 30 days and should have been deleted"
done
for f in db-old29.dump photos-old29.tar.gz unrelated.txt; do
  [[ -e "$BACKUP_DIR/$f" ]] || die "$f should have been kept"
done
grep -q "4 old file(s) removed" <<<"$out" || die "expected the log to count 4 removed files"
pass "4. backups older than 30 days deleted, newer ones (and other files) kept"

if grep -qF "$PASSWORD" <<<"$out"; then die "the database password appeared in the log"; fi
grep -qE "database [0-9.]+[KMG]?, photos [0-9.]+[KMG]?" <<<"$out" || die "log should give sizes: $out"
pass "5. the log has counts and sizes only"

cmp -s "$ROOT/staging/backup.sh" "$ROOT/production/backup.sh" || die "staging/backup.sh and production/backup.sh must be identical"
pass "staging and production run the same backup script"
