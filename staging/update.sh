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
#   5. runs that build's own smoke-test image against staging (SCRUM-17);
#   6. if the health check or smoke tests fail, records the image as known-bad
#      and puts the previous image back;
#   7. posts the outcome to the image's commit on GitHub as a "staging/home-server"
#      commit status (if a status token is installed).
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
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-120}"
SMOKE_SERVICES="${SMOKE_SERVICES:-site}"
SMOKE_TIMEOUT="${SMOKE_TIMEOUT:-600}"
_bind="${STAGING_BIND:-0.0.0.0}"
[[ "$_bind" == "0.0.0.0" ]] && _bind="127.0.0.1"
SMOKE_BASE_URL="${SMOKE_BASE_URL:-http://$_bind:${STAGING_PORT:-8088}}"
STAGING_PUBLIC_URL="${STAGING_PUBLIC_URL:-http://home-server:${STAGING_PORT:-8088}}"
GITHUB_API="${GITHUB_API:-https://api.github.com}"
GITHUB_STATUS_TOKEN_FILE="${GITHUB_STATUS_TOKEN_FILE:-/etc/picklemypaddle/github-status.token}"
STATUS_CONTEXT="${STATUS_CONTEXT:-staging/home-server}"

compose() {
  docker compose --project-directory "$STACK_DIR" -f "$STACK_DIR/compose.staging.yml" "$@"
}
log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*"; }
short() { local id="${1#sha256:}"; printf '%s' "${id:0:12}"; }

image_of() {
  compose config --format json |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["services"][sys.argv[1]]["image"])' "$1"
}

# Services to keep current: those labelled com.picklemypaddle.autoupdate=true.
autoupdate_services() {
  compose config --format json | python3 -c '
import json, sys
for name, svc in json.load(sys.stdin)["services"].items():
    labels = svc.get("labels") or {}
    if isinstance(labels, list):
        labels = dict(l.split("=", 1) for l in labels)
    if str(labels.get("com.picklemypaddle.autoupdate", "")).lower() == "true":
        print(name)'
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

label_of() { # label_of <image-id> <label>
  docker image inspect -f "{{index .Config.Labels \"$2\"}}" "$1" 2>/dev/null || true
}
rev_of() { label_of "$1" org.opencontainers.image.revision; }

# Post a commit status to GitHub for the commit an image was built from.
# Never fails the run: reporting is best-effort.
report() { # report <image-id> <pending|success|failure|error> <description>
  local id="$1" state="$2" desc="$3" rev src owner_repo body
  [[ -r "$GITHUB_STATUS_TOKEN_FILE" ]] || return 0
  rev="$(rev_of "$id")"
  src="$(label_of "$id" org.opencontainers.image.source)"
  owner_repo="${src#https://github.com/}"
  if [[ -z "$rev" || "$owner_repo" == "$src" ]]; then
    log "status: image $(short "$id") has no revision/source label; not reported"
    return 0
  fi
  body="$(python3 -c 'import json,sys; print(json.dumps({"state":sys.argv[1],"description":sys.argv[2][:140],"context":sys.argv[3],"target_url":sys.argv[4]}))' \
    "$state" "$desc" "$STATUS_CONTEXT" "$STAGING_PUBLIC_URL")"
  # The token goes to curl on stdin, so it never appears in the process list.
  if ! printf 'header = "Authorization: Bearer %s"\n' "$(tr -d '[:space:]' <"$GITHUB_STATUS_TOKEN_FILE")" |
    curl -fsS --config - --max-time 20 -o /dev/null -X POST \
      -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" \
      "$GITHUB_API/repos/$owner_repo/statuses/$rev" -d "$body"; then
    log "status: could not post '$state' to $owner_repo@${rev:0:7} (token expired or wrong repo?)"
  fi
}

# Make sure the gateway is up, so smoke tests go through the real entry point.
ensure_gateway() {
  compose up -d --pull missing --no-recreate --wait --wait-timeout "$HEALTH_TIMEOUT" gateway >/dev/null 2>&1
}

# Run the smoke-test image built from the same commit (<repo>-smoke:<sha>).
# Returns 0 = passed, 1 = failed, 2 = could not run (no image, no label, ...).
run_smoke() { # run_smoke <service> <image-id> <repo>
  local svc="$1" id="$2" repo="$3" rev smoke prev name="pmp-smoke-$1" rc=0
  [[ " $SMOKE_SERVICES " == *" $svc "* ]] || return 0
  rev="$(rev_of "$id")"
  [[ -n "$rev" ]] || { log "$svc: image has no revision label; can't pick smoke tests"; return 2; }
  smoke="$repo-smoke:$rev"
  if ! docker pull -q "$smoke" >/dev/null 2>&1; then
    log "$svc: smoke-test image $smoke not found"
    return 2
  fi
  ensure_gateway || { log "$svc: gateway not healthy, can't run smoke tests"; return 1; }
  log "$svc: running smoke tests ($smoke) against $SMOKE_BASE_URL"
  docker rm -f "$name" >/dev/null 2>&1 || true
  timeout "$SMOKE_TIMEOUT" docker run --name "$name" --rm --network host --shm-size=1g \
    --cap-drop ALL --security-opt no-new-privileges -e BASE_URL="$SMOKE_BASE_URL" \
    "$smoke" >"$STATE_DIR/$svc.smoke.log" 2>&1 || rc=1
  docker rm -f "$name" >/dev/null 2>&1 || true
  tail -n 5 "$STATE_DIR/$svc.smoke.log" | sed "s/^/$svc smoke | /"
  # Keep only the latest smoke image (they're large; base layers stay cached).
  prev="$(cat "$STATE_DIR/$svc.smoke-image" 2>/dev/null || true)"
  if [[ -n "$prev" && "$prev" != "$smoke" ]]; then
    docker image rm "$prev" >/dev/null 2>&1 || true
  fi
  echo "$smoke" >"$STATE_DIR/$svc.smoke-image"
  return "$rc"
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
    log "$svc: $(short "$new_id") failed its checks earlier; staying on $(short "$running_id")"
    return 0
  fi

  log "$svc: deploying $(short "$new_id") (was $(short "${running_id:-none}"))"
  report "$new_id" pending "Deploying to home-server staging"
  compose up -d --no-deps --pull never "$svc" >/dev/null 2>&1 || true

  local reason="" smoke_rc=0
  if ! wait_healthy "$svc"; then
    reason="Health check failed"
  else
    run_smoke "$svc" "$new_id" "$repo" || smoke_rc=$?
    [[ $smoke_rc -eq 1 ]] && reason="Smoke tests failed"
  fi

  if [[ -z "$reason" ]]; then
    if [[ -n "$running_id" ]]; then
      old_prev="$(docker image inspect -f '{{.Id}}' "$repo:previous" 2>/dev/null || true)"
      docker tag "$running_id" "$repo:previous"
      if [[ -n "$old_prev" && "$old_prev" != "$running_id" && "$old_prev" != "$new_id" ]]; then
        docker image rm "$old_prev" >/dev/null 2>&1 || true
      fi
    fi
    printf '%s %s %s\n' "$(date -u +%FT%TZ)" "$new_id" "$(rev_of "$new_id")" >>"$STATE_DIR/$svc.deployed"
    if [[ $smoke_rc -eq 2 ]]; then
      log "$svc: $(short "$new_id") is healthy and live, but smoke tests could not run"
      report "$new_id" error "Live on staging, but smoke tests could not run (see journal on home-server)"
    else
      log "$svc: $(short "$new_id") is healthy and live"
      report "$new_id" success "Live on staging: health check and smoke tests passed"
    fi
    return 0
  fi

  log "$svc: $(short "$new_id"): $reason; rolling back"
  echo "$new_id" >>"$bad_file"
  tail -n 20 "$bad_file" >"$bad_file.tmp" && mv "$bad_file.tmp" "$bad_file"
  if [[ -n "$running_id" ]]; then
    docker tag "$running_id" "$image"
    compose up -d --no-deps --pull never "$svc" >/dev/null 2>&1 || true
    local back
    back="$(rev_of "$running_id")"
    back="${back:0:7}"
    back="${back:-$(short "$running_id")}"
    if wait_healthy "$svc"; then
      log "$svc: rolled back to $(short "$running_id")"
      report "$new_id" failure "$reason; staging rolled back to $back"
    else
      log "$svc: rollback to $(short "$running_id") is ALSO unhealthy; needs a look"
      report "$new_id" failure "$reason; rollback to $back is also unhealthy"
    fi
  else
    log "$svc: no previous image to roll back to"
    report "$new_id" failure "$reason; no previous version to roll back to"
  fi
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
  for svc in $(autoupdate_services); do
    update_service "$svc" || status=1
  done

  # Start anything that isn't running yet (first install, after a crash, the
  # gateway). Only pulls images that are missing locally; the gateway's Caddy
  # image is refreshed by re-running install.sh, not every 2 minutes (Docker
  # Hub rate-limits anonymous pulls).
  compose up -d --pull missing --no-recreate --wait --wait-timeout "$HEALTH_TIMEOUT" >/dev/null 2>&1 || {
    log "stack: some containers did not start or are unhealthy; see 'docker compose ps'"
    status=1
  }
  exit "$status"
}

main "$@"
