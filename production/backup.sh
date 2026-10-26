#!/usr/bin/env bash
# PickleMyPaddle nightly backup of the order database and photos (SCRUM-64).
#
# Writes into BACKUP_DIR on this host (root-only):
#   db-<UTC time>.dump          pg_dump of the order database, custom format (restore: pg_restore)
#   photos-<UTC time>.tar.gz    the photo volume
# and deletes backups older than BACKUP_KEEP_DAYS (30). Logs counts and sizes only.
# Copying the folder off this server is decided in SCRUM-44.
#
# The same file runs on staging (home-server) and production (the VPS); it finds the stack's
# compose file next to itself. Run by the pmp-<stack>-backup timer; by hand: sudo ./backup.sh
set -euo pipefail

STACK_DIR="${STACK_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
if [[ -f "$STACK_DIR/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  . "$STACK_DIR/.env"
  set +a
fi
shopt -s nullglob
files=("$STACK_DIR"/compose.*.yml)
shopt -u nullglob
[[ ${#files[@]} -eq 1 ]] || { echo "expected one compose.*.yml in $STACK_DIR, found ${#files[@]}" >&2; exit 1; }
COMPOSE_FILE_PATH="${files[0]}"
STACK="$(basename "$COMPOSE_FILE_PATH" .yml)"; STACK="${STACK#compose.}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/picklemypaddle/$STACK}"
BACKUP_KEEP_DAYS="${BACKUP_KEEP_DAYS:-30}"
DB_USER="${DB_USER:-pmp}"
DB_NAME="${DB_NAME:-pmp}"

compose() { docker compose --project-directory "$STACK_DIR" -f "$COMPOSE_FILE_PATH" "$@"; }
log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*"; }
size() { du -h "$1" | cut -f1; }

[[ "$BACKUP_KEEP_DAYS" =~ ^[1-9][0-9]*$ ]] || { log "BACKUP_KEEP_DAYS must be a whole number of days"; exit 1; }
cid="$(compose ps -q postgres 2>/dev/null | head -n1 || true)"
if [[ -z "$cid" ]]; then
  # Production before orders are switched on: nothing to back up yet.
  log "postgres is not running in the $STACK stack; nothing to back up"
  exit 0
fi

umask 077
install -d -m 0700 "$BACKUP_DIR"
ts="$(date -u +%Y%m%dT%H%M%SZ)"
db_file="$BACKUP_DIR/db-$ts.dump"
photo_file="$BACKUP_DIR/photos-$ts.tar.gz"
cleanup() { rm -f "$db_file.part" "$photo_file.part"; }
trap cleanup EXIT

# Written as .part and renamed when complete, so a failed run never leaves a backup that looks good.
docker exec "$cid" pg_dump -U "$DB_USER" -d "$DB_NAME" --format=custom >"$db_file.part"
mv "$db_file.part" "$db_file"

photo_volume="$(compose config --format json | python3 -c 'import json,sys; print((json.load(sys.stdin).get("volumes") or {}).get("photos", {}).get("name", ""))')"
if [[ -n "$photo_volume" ]] && docker volume inspect "$photo_volume" >/dev/null 2>&1; then
  # The postgres image is already on this host and has tar; no network needed.
  docker run --rm --network none -v "$photo_volume:/src:ro" --entrypoint tar \
    "$(docker inspect -f '{{.Config.Image}}' "$cid")" -C /src -czf - . >"$photo_file.part"
  mv "$photo_file.part" "$photo_file"
  photos="photos $(size "$photo_file")"
else
  photos="no photo volume yet"
fi

# find -mtime +N matches files at least N+1 whole days old.
pruned="$(find "$BACKUP_DIR" -maxdepth 1 -type f \( -name 'db-*.dump' -o -name 'photos-*.tar.gz' \) \
  -mtime +"$((BACKUP_KEEP_DAYS - 1))" -print -delete | wc -l)"
kept="$(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'db-*.dump' | wc -l)"
log "backup done ($STACK): database $(size "$db_file"), $photos; $pruned old file(s) removed; $kept database backup(s) kept, total $(du -sh "$BACKUP_DIR" | cut -f1)"
