#!/usr/bin/env bash
# Pickle My Paddle staging updater (SCRUM-16).
#
# Run every 2 minutes by the pmp-staging-update.timer on home-server. For each
# component it:
#   1. pulls the component's :staging image from the registry (GHCR);
#   2. does nothing if that is the image already running;
#   3. skips images that already failed their health check here (known-bad);
#   4. otherwise restarts the component on the new image and waits for its
#      Docker health check;
#   5. if the new image is unhealthy, records it as known-bad and puts the
#      previous image back.
#
# It only pulls and runs published images: nothing here fetches or executes code
# from the (public) GitHub repos. Exit code: 0 = all fine, 1 = something failed
# (shown as a failed run in `systemctl status` and the journal).
set -euo pipefail

STACK_DIR="${STACK_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
if [[ -f "$STACK_DIR/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  . "$STACK_DIR/.env"
  set +a
fi
STATE_DIR="${STATE_DIR:-/var/lib/pmp-staging}"
UPDATE_SERVICES="${UPDATE_SERVICES:-site}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-120}"

compose() {
  docker compose --project-directory "$STACK_DIR" -f "$STACK_DIR/compose.staging.yml" "$@"
}
log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*"; }
short() { local id="${1#sha256:}"; printf '%s' "${id:0:12}"; }

image_of() {
  compose config --format json |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["services"][sys.argv[1]]["image"])' "$1"
}

container_of() { compose ps -q "$1" 2>/dev/null | head -n1; }

# Wait for a service's container to report healthy. Returns 1 on unhealthy/timeout.
wait_healthy() {
  local svc="$1" deadline=$((SECONDS + HEALTH_TIMEOUT)) cid state
  while ((SECONDS < deadline)); do
    cid="$(container_of "$svc")"
    if [[ -n "$cid" ]]; then
      state="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid" 2>/dev/null || echo missing)"
      case "$state" in
        healthy | none) return 0 ;;
        unhealthy) return 1 ;;
      esac
    fi
    sleep 3
  done
  return 1
}

# Optional hook for SCRUM-17 (smoke tests + GitHub commit status).
run_hook() {
  local hook="$STACK_DIR/hooks/$1"
  shift
  if [[ -x "$hook" ]]; then "$hook" "$@" || log "hook $(basename "$hook") failed (ignored)"; fi
}

update_service() {
  local svc="$1" image repo cid running_id new_id bad_file old_prev
  image="$(image_of "$svc")"
  repo="${image%:*}"
  bad_file="$STATE_DIR/$svc.known-bad"
  cid="$(container_of "$svc")"
  running_id=""
  [[ -n "$cid" ]] && running_id="$(docker inspect -f '{{.Image}}' "$cid")"

  if ! docker pull -q "$image" >/dev/null; then
    log "$svc: could not pull $image (registry unreachable or image private?)"
    return 1
  fi
  new_id="$(docker image inspect -f '{{.Id}}' "$image")"

  if [[ "$new_id" == "$running_id" ]]; then
    return 0
  fi

  if [[ -f "$bad_file" ]] && grep -qx "$new_id" "$bad_file"; then
    # Keep the tag on the image that is actually running, so a reboot or a
    # manual `docker compose up` doesn't start the known-bad one.
    [[ -n "$running_id" ]] && docker tag "$running_id" "$image"
    log "$svc: $(short "$new_id") failed its health check earlier; staying on $(short "$running_id")"
    return 0
  fi

  log "$svc: deploying $(short "$new_id") (was $(short "${running_id:-none}"))"
  compose up -d --no-deps --pull never "$svc" >/dev/null 2>&1 || true

  if wait_healthy "$svc"; then
    if [[ -n "$running_id" ]]; then
      old_prev="$(docker image inspect -f '{{.Id}}' "$repo:previous" 2>/dev/null || true)"
      docker tag "$running_id" "$repo:previous"
      if [[ -n "$old_prev" && "$old_prev" != "$running_id" && "$old_prev" != "$new_id" ]]; then
        docker image rm "$old_prev" >/dev/null 2>&1 || true
      fi
    fi
    printf '%s %s\n' "$(date -u +%FT%TZ)" "$new_id" >>"$STATE_DIR/$svc.deployed"
    log "$svc: $(short "$new_id") is healthy and live"
    run_hook after-deploy "$svc" "$new_id" healthy
    return 0
  fi

  log "$svc: $(short "$new_id") is UNHEALTHY; rolling back"
  echo "$new_id" >>"$bad_file"
  tail -n 20 "$bad_file" >"$bad_file.tmp" && mv "$bad_file.tmp" "$bad_file"
  if [[ -n "$running_id" ]]; then
    docker tag "$running_id" "$image"
    compose up -d --no-deps --pull never "$svc" >/dev/null 2>&1 || true
    if wait_healthy "$svc"; then
      log "$svc: rolled back to $(short "$running_id")"
    else
      log "$svc: rollback to $(short "$running_id") is ALSO unhealthy; needs a look"
    fi
  else
    log "$svc: no previous image to roll back to"
  fi
  run_hook after-deploy "$svc" "$new_id" rolled-back
  return 1
}

main() {
  mkdir -p "$STATE_DIR"
  exec 9>"$STATE_DIR/update.lock"
  if ! flock -n 9; then
    log "another update is already running; skipping this run"
    exit 0
  fi

  local status=0 svc
  for svc in $UPDATE_SERVICES; do
    update_service "$svc" || status=1
  done

  # Start anything that isn't running yet (first install, after a crash, the
  # gateway). Only pulls images that are missing locally; the gateway's Caddy
  # image is refreshed by re-running install.sh, not every 2 minutes (Docker
  # Hub rate-limits anonymous pulls).
  compose up -d --pull missing --no-recreate >/dev/null 2>&1 || {
    log "stack: some containers did not start; see 'docker compose ps'"
    status=1
  }
  exit "$status"
}

main "$@"
