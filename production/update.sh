#!/usr/bin/env bash
# PickleMyPaddle production updater (SCRUM-19). Manual and approved: nothing runs this
# by itself (there is no timer), and production only ever runs release tags (vX.Y.Z)
# that already went through CI and staging.
#
#   sudo ./update.sh status               what is running, what is pinned, recent deploys
#   sudo ./update.sh check                run the live-site checks again (changes nothing)
#   sudo ./update.sh deploy vX.Y.Z        show what changes, ask, then deploy that release
#   sudo ./update.sh deploy vX.Y.Z --yes  the same without the question (you reviewed it)
#   sudo ./update.sh rollback [--yes]     go back to the release that ran before the last deploy
#
# A deploy pulls the release image, starts it, waits for its Docker health check, then
# checks the live site through the gateway: it serves this release's commit, has its security
# headers, is indexable, and shows no staging address. If anything fails the previous
# release is put back (on a first deploy the site is stopped and visitors see the gateway's
# "temporarily unavailable" page). .env records the release only after the checks pass.
# Exit codes: 0 = done or nothing to do, 1 = failed (and rolled back), 2 = usage.
set -euo pipefail

STACK_DIR="${STACK_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
STATE_DIR="${STATE_DIR:-/var/lib/pmp-production}"
ENV_FILE="$STACK_DIR/.env"

# Read one setting from .env without running it as shell (values can contain ';' and spaces).
env_get() { # env_get <KEY>
  [[ -f "$ENV_FILE" ]] || return 0
  sed -n "s/^$1=//p" "$ENV_FILE" | tail -n1 | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/"
}

# Environment variables win over .env (as they do for docker compose).
DOMAIN="${SITE_DOMAIN:-$(env_get SITE_DOMAIN)}"
DOMAIN="${DOMAIN:-picklemypaddle.com}"
REPO="${SITE_IMAGE_REPO:-$(env_get SITE_IMAGE_REPO)}"
REPO="${REPO:-ghcr.io/thehunfromoz/picklemypaddle-site}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-$(env_get HEALTH_TIMEOUT)}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-120}"
VERIFY_TRIES="${VERIFY_TRIES:-5}"
VERIFY_WAIT="${VERIFY_WAIT:-3}"
# Extra curl options for the live-site checks. Tests pass -k (their gateway uses Caddy's internal CA).
read -r -a CURL_OPTS <<<"${PMP_CURL_OPTS:-}"

ASSUME_YES=false
REASON=""

compose() {
  docker compose --project-directory "$STACK_DIR" -f "$STACK_DIR/compose.production.yml" "$@"
}
log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*"; }
ok() { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*" >&2; }
die() { bad "$*"; exit 1; }
short() { local id="${1#sha256:}"; printf '%s' "${id:0:12}"; }

usage() {
  cat >&2 <<USAGE
usage: sudo $0 status
       sudo $0 check
       sudo $0 deploy vX.Y.Z [--yes]
       sudo $0 rollback [--yes]
USAGE
  exit 2
}

label_of() { # label_of <image> <label>
  docker image inspect -f "{{index .Config.Labels \"$2\"}}" "$1" 2>/dev/null || true
}
rev_of() { label_of "$1" org.opencontainers.image.revision; }
container_of() { compose ps -q "${1:-site}" 2>/dev/null | head -n1; }

# Wait for the site container to report healthy. Returns 1 on unhealthy/timeout.
wait_healthy() {
  local deadline=$((SECONDS + HEALTH_TIMEOUT)) cid state
  while ((SECONDS < deadline)); do
    cid="$(container_of site)"
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

# Requests go to this server's own gateway but use the real hostname, so the certificate is
# checked exactly as a visitor's browser would (and no DNS or hairpin routing is involved).
site_get() { # site_get <path> [curl options]: body on stdout, fails on an HTTP error
  local path="$1"
  shift
  curl -fsS --max-time 15 "${CURL_OPTS[@]}" --resolve "www.$DOMAIN:443:127.0.0.1" "$@" "https://www.$DOMAIN$path"
}
site_headers() { site_get "$1" -D - -o /dev/null; }

# The live-site checks. On failure: sets $REASON and returns 1.
verify_live() { # verify_live <commit the running release was built from>
  local rev="$1" got headers page robots sitemap css
  site_get /healthz >/dev/null 2>&1 || { REASON="the site does not answer through the gateway (https://www.$DOMAIN/healthz)"; return 1; }
  got="$(site_get /version.txt 2>/dev/null | tr -d '[:space:]')" || got=""
  [[ "$got" == "$rev" ]] || { REASON="/version.txt says '${got:-nothing}', expected this release's commit ${rev:0:7}"; return 1; }
  headers="$(site_headers / 2>/dev/null)" || { REASON="the home page does not load"; return 1; }
  grep -qi '^strict-transport-security:' <<<"$headers" || { REASON="the home page has no Strict-Transport-Security header"; return 1; }
  grep -qi '^content-security-policy:' <<<"$headers" || { REASON="the home page has no Content-Security-Policy header"; return 1; }
  if grep -qi '^x-robots-tag:.*noindex' <<<"$headers"; then
    REASON="the home page says noindex (a staging setting; production must be indexable)"
    return 1
  fi
  page="$(site_get / 2>/dev/null)" || { REASON="the home page does not load"; return 1; }
  if grep -qi 'home-server' <<<"$page"; then
    REASON="the home page still points at the staging address (home-server): this image was built with the staging SITE_URL"
    return 1
  fi
  robots="$(site_get /robots.txt 2>/dev/null)" || { REASON="/robots.txt is missing"; return 1; }
  if grep -qx 'Disallow: /' <<<"$robots"; then
    REASON="/robots.txt blocks the whole site (a staging setting)"
    return 1
  fi
  if grep -qi 'home-server' <<<"$robots"; then REASON="/robots.txt points at the staging address (home-server)"; return 1; fi
  sitemap="$(site_get /sitemap-index.xml 2>/dev/null)" || { REASON="/sitemap-index.xml is missing"; return 1; }
  if grep -qi 'home-server' <<<"$sitemap"; then REASON="the sitemap points at the staging address (home-server)"; return 1; fi
  css="$(site_get /env.css 2>/dev/null)" || css=""
  if grep -q 'display: *block' <<<"$css"; then REASON="/env.css reveals the staging-only elements (Preview ribbon, test-order notice)"; return 1; fi
  return 0
}

# The site can take a few seconds to show up behind the gateway after it starts.
verify_live_retry() { # verify_live_retry <commit>
  local i
  for ((i = 1; i <= VERIFY_TRIES; i++)); do
    if verify_live "$1"; then return 0; fi
    if ((i < VERIFY_TRIES)); then sleep "$VERIFY_WAIT"; fi
  done
  return 1
}

confirm() { # confirm <question>
  if $ASSUME_YES; then return 0; fi
  [[ -t 0 ]] || die "no terminal to ask on: review the changes, then add --yes"
  local ans
  read -r -p "  $1 [y/N] " ans
  [[ "${ans,,}" == y || "${ans,,}" == yes ]]
}

# Record the release in .env (only called after the checks passed). Values are vX.Y.Z, so safe in sed.
set_pinned() { # set_pinned <version>
  local tmp
  tmp="$(mktemp "$STACK_DIR/.env.XXXXXX")"
  if grep -q '^SITE_VERSION=' "$ENV_FILE" 2>/dev/null; then
    sed "s|^SITE_VERSION=.*|SITE_VERSION=$1|" "$ENV_FILE" >"$tmp"
  else
    { cat "$ENV_FILE" 2>/dev/null || true; printf 'SITE_VERSION=%s\n' "$1"; } >"$tmp"
  fi
  chmod 0644 "$tmp"
  mv "$tmp" "$ENV_FILE"
}

deploy_release() { # deploy_release <version> <deploy|rollback>
  local version="$1" what="$2" image new_id new_rev src cid run_id="" run_ver="" run_rev=""
  [[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
    die "'$version' is not a release version (vX.Y.Z). Production never runs :staging, :latest or a commit tag."
  image="$REPO:$version"
  docker pull -q "$image" >/dev/null 2>&1 ||
    die "cannot pull $image. Is $version a published release? (Draft it on GitHub, see the runbook.)"
  new_id="$(docker image inspect -f '{{.Id}}' "$image")"
  new_rev="$(rev_of "$new_id")"
  [[ -n "$new_rev" ]] || die "$image has no revision label, so it can't be matched to a commit"
  src="$(label_of "$new_id" org.opencontainers.image.source)"

  cid="$(container_of site)"
  if [[ -n "$cid" ]]; then
    run_id="$(docker inspect -f '{{.Image}}' "$cid")"
    run_ver="$(docker inspect -f '{{.Config.Image}}' "$cid")"
    run_ver="${run_ver##*:}"
    run_rev="$(rev_of "$run_id")"
  fi
  if [[ "$new_id" == "$run_id" ]]; then
    ok "$version is already running (commit ${new_rev:0:7}); nothing to do"
    return 0
  fi

  printf '\n  Production: https://www.%s\n' "$DOMAIN"
  if [[ -n "$run_ver" ]]; then
    printf '    running : %s (commit %s)\n' "$run_ver" "${run_rev:0:7}"
  else
    printf "    running : nothing (visitors see the 'temporarily unavailable' page)\n"
  fi
  printf '    %s : %s (commit %s)\n' "$what" "$version" "${new_rev:0:7}"
  if [[ -n "$run_rev" && -n "$src" ]]; then printf '    changes : %s/compare/%s...%s\n' "$src" "$run_rev" "$new_rev"; fi
  printf '\n'
  if ! confirm "${what^} $version to https://www.$DOMAIN ?"; then
    echo "  Not deployed. Nothing changed."
    return 0
  fi

  log "$what: starting $version"
  REASON=""
  SITE_VERSION="$version" compose up -d --no-deps --pull never site >/dev/null 2>&1 || true
  if ! wait_healthy; then
    REASON="the container did not become healthy within ${HEALTH_TIMEOUT}s"
  else
    verify_live_retry "$new_rev" || true
  fi

  if [[ -z "$REASON" ]]; then
    set_pinned "$version"
    if [[ -n "$run_ver" && "$run_ver" != "$version" ]]; then printf '%s\n' "$run_ver" >"$STATE_DIR/site.previous-version"; fi
    printf '%s %s %s %s\n' "$(date -u +%FT%TZ)" "$version" "$new_rev" "$(short "$new_id")" >>"$STATE_DIR/site.deployed"
    ok "$version is live at https://www.$DOMAIN (commit ${new_rev:0:7})"
    return 0
  fi

  bad "$version: $REASON"
  printf '%s %s %s\n' "$(date -u +%FT%TZ)" "$version" "$REASON" >>"$STATE_DIR/site.failed"
  if [[ -n "$run_ver" ]]; then
    log "putting $run_ver back"
    SITE_VERSION="$run_ver" compose up -d --no-deps --pull never site >/dev/null 2>&1 || true
    if wait_healthy; then
      ok "rolled back: $run_ver is serving again, production is as it was"
    else
      bad "the rollback to $run_ver is ALSO unhealthy; look: sudo docker compose -p pmp-production logs --tail 30 site"
    fi
  else
    compose stop site >/dev/null 2>&1 || true
    compose rm -f site >/dev/null 2>&1 || true
    bad "there was no earlier release, so the site is stopped: visitors see the 'temporarily unavailable' page"
  fi
  return 1
}

cmd_status() {
  local pinned cid id gw
  pinned="$(env_get SITE_VERSION)"
  printf 'Production: https://www.%s\n' "$DOMAIN"
  gw="$(container_of gateway)"
  if [[ -n "$gw" ]]; then
    printf '  gateway          : %s\n' "$(docker inspect -f '{{.State.Status}}, health {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}, since {{.State.StartedAt}}' "$gw")"
  else
    printf '  gateway          : not running (sudo ./production/install.sh)\n'
  fi
  cid="$(container_of site)"
  if [[ -n "$cid" ]]; then
    id="$(docker inspect -f '{{.Image}}' "$cid")"
    printf '  site running     : %s (commit %s), %s\n' "$(docker inspect -f '{{.Config.Image}}' "$cid" | sed 's/.*://')" \
      "$(rev_of "$id" | cut -c1-7)" \
      "$(docker inspect -f '{{.State.Status}}, health {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}, since {{.State.StartedAt}}' "$cid")"
  else
    printf '  site running     : nothing\n'
  fi
  printf '  pinned in .env   : %s\n' "${pinned:-none yet}"
  printf '  rollback target  : %s\n' "$(cat "$STATE_DIR/site.previous-version" 2>/dev/null || echo none)"
  if [[ -s "$STATE_DIR/site.deployed" ]]; then
    printf '  recent deploys   :\n'
    tail -n 5 "$STATE_DIR/site.deployed" | sed 's/^/    /'
  fi
  if [[ -s "$STATE_DIR/site.failed" ]]; then
    printf '  recent failures  :\n'
    tail -n 3 "$STATE_DIR/site.failed" | sed 's/^/    /'
  fi
}

cmd_check() {
  local cid id rev
  cid="$(container_of site)"
  [[ -n "$cid" ]] || die "the site is not running, nothing to check"
  id="$(docker inspect -f '{{.Image}}' "$cid")"
  rev="$(rev_of "$id")"
  [[ -n "$rev" ]] || die "the running image has no revision label"
  REASON=""
  if verify_live_retry "$rev"; then
    ok "https://www.$DOMAIN serves commit ${rev:0:7} and passes every live-site check"
  else
    die "$REASON"
  fi
}

cmd_rollback() {
  local prev
  prev="$(cat "$STATE_DIR/site.previous-version" 2>/dev/null || true)"
  [[ -n "$prev" ]] || die "no earlier release is recorded, so there is nothing to roll back to"
  deploy_release "$prev" rollback
}

main() {
  [[ $EUID -eq 0 || -n "${PMP_TEST:-}" ]] || die "run with sudo"
  local cmd="${1:-status}" version="" arg
  if [[ $# -gt 0 ]]; then shift; fi
  for arg in "$@"; do
    case "$arg" in
      --yes | -y) ASSUME_YES=true ;;
      -*) usage ;;
      *)
        [[ -z "$version" ]] || usage
        version="$arg"
        ;;
    esac
  done
  mkdir -p "$STATE_DIR"
  exec 9>"$STATE_DIR/update.lock"
  flock -n 9 || die "another update is already running"
  case "$cmd" in
    status) cmd_status ;;
    check) cmd_check ;;
    deploy)
      [[ -n "$version" ]] || usage
      deploy_release "$version" deploy
      ;;
    rollback) cmd_rollback ;;
    *) usage ;;
  esac
}

main "$@"
