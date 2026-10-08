#!/usr/bin/env bash
# Integration test for staging/update.sh (SCRUM-16), run in CI on a throwaway
# Docker host. Uses a local registry and stand-in images so it can push a
# healthy release, a broken release and a fix, exactly as GHCR would.
#
# Scenarios (from the story's tests):
#   1. first run deploys version A and serves it through the gateway
#   2. a broken image is detected, recorded and rolled back; A keeps serving
#   3. the next run doesn't retry the broken image
#   4. a fixed image (B) is deployed
#   5. nothing changes when there is no new image
#   6. healthy image whose smoke tests fail is rolled back (SCRUM-17)
#   7. image without a smoke-test image stays live, status "error"
# Every deploy's outcome is checked as a commit status on a fake GitHub API.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
REG="localhost:5000"
IMG="$REG/pmp-test/site"
PORT=18088
STATUSES="$WORK/statuses.log"
export STACK_DIR="$WORK/stack" STATE_DIR="$WORK/state" HEALTH_TIMEOUT=60
export GITHUB_API="http://127.0.0.1:9999" GITHUB_STATUS_TOKEN_FILE="$WORK/token"

pass() { printf '\033[32mPASS\033[0m %s\n' "$*"; }
die() {
  printf '\033[31mFAIL\033[0m %s\n' "$*" >&2
  local out
  out="$(docker ps -a --format '{{.Names}} {{.Status}}'
    docker compose --project-directory "$STACK_DIR" -f "$STACK_DIR/compose.staging.yml" logs --tail 15 2>&1)"
  echo "$out" >&2
  # Also as a GitHub annotation, so the failure is readable from the API.
  [[ -n "${GITHUB_ACTIONS:-}" ]] && echo "::error title=$1::${out//$'\n'/%0A}"
  exit 1
}
cleanup() {
  docker compose --project-directory "$STACK_DIR" -f "$STACK_DIR/compose.staging.yml" down -v >/dev/null 2>&1 || true
  docker rm -f pmp-test-registry >/dev/null 2>&1 || true
  if [[ -n "${API_PID:-}" ]]; then kill "$API_PID" 2>/dev/null || true; fi
  rm -rf "$WORK"
}
trap cleanup EXIT
trap 'die "unexpected failure at line $LINENO"' ERR

publish() { # publish <version> <health-status> [no-smoke]
  docker build -q -t "$IMG:staging" --build-arg VERSION="$1" --build-arg HEALTH="$2" \
    --label org.opencontainers.image.revision="rev-$1" \
    --label org.opencontainers.image.source=https://github.com/test/site \
    "$ROOT/tests/fixtures" >/dev/null
  docker push -q "$IMG:staging" >/dev/null
  docker rmi "$IMG:staging" >/dev/null # make the updater really pull it
  if [[ "${3:-}" != no-smoke ]]; then
    docker build -q -t "$IMG-smoke:rev-$1" -f "$ROOT/tests/fixtures/smoke.Dockerfile" "$ROOT/tests/fixtures" >/dev/null
    docker push -q "$IMG-smoke:rev-$1" >/dev/null
    docker rmi "$IMG-smoke:rev-$1" >/dev/null
  fi
}
# Last status posted for a commit, as "<state> | <description>".
status_of() {
  grep "^/repos/test/site/statuses/rev-$1 " "$STATUSES" | tail -n1 |
    sed -E 's/^[^ ]+ Bearer test-token ([a-z]+) staging\/home-server \| /\1 | /'
}
served() { curl -fsS "http://127.0.0.1:$PORT/" 2>/dev/null || echo "(no answer)"; }
update() { "$STACK_DIR/update.sh"; }

docker run -d --name pmp-test-registry -p 5000:5000 registry:2 >/dev/null
echo "test-token" >"$GITHUB_STATUS_TOKEN_FILE"
python3 "$ROOT/tests/fixtures/fake_github.py" "$STATUSES" &
API_PID=$!
# Stand-in integrations service (labelled for auto-update like the site) and its
# empty secrets file.
: >"$WORK/integrations.env"
docker build -q -t "$REG/pmp-test/integrations:staging" --build-arg VERSION=INT --build-arg HEALTH=200 \
  --label org.opencontainers.image.revision=rev-INT --label org.opencontainers.image.source=https://github.com/test/integrations \
  "$ROOT/tests/fixtures" >/dev/null
docker push -q "$REG/pmp-test/integrations:staging" >/dev/null
docker rmi "$REG/pmp-test/integrations:staging" >/dev/null
mkdir -p "$STACK_DIR/gateway"
cp "$ROOT/staging/compose.staging.yml" "$ROOT/staging/update.sh" "$STACK_DIR/"
cp "$ROOT/staging/gateway/Caddyfile" "$STACK_DIR/gateway/"
sed -e "s|^STAGING_PORT=.*|STAGING_PORT=$PORT|" \
    -e "s|^STAGING_BIND=.*|STAGING_BIND=127.0.0.1|" \
    -e "s|^SITE_IMAGE=.*|SITE_IMAGE=$IMG:staging|" \
    -e "s|^INTEGRATIONS_IMAGE=.*|INTEGRATIONS_IMAGE=$REG/pmp-test/integrations:staging|" \
    -e "s|^INTEGRATIONS_ENV_FILE=.*|INTEGRATIONS_ENV_FILE=$WORK/integrations.env|" \
    -e "s|^HEALTH_TIMEOUT=.*|HEALTH_TIMEOUT=60|" \
    "$ROOT/staging/.env.example" >"$STACK_DIR/.env"
sleep 2

# 1 ── first deploy
publish A 200
update || die "first run should succeed"
[[ "$(served)" == "version A" ]] || die "expected version A, got: $(served)"
[[ "$(curl -fsS "http://127.0.0.1:$PORT/healthz")" == "health 200" ]] || die "/healthz not routed to the site"
curl -fsSI "http://127.0.0.1:$PORT/" | grep -qi '^server:' && die "gateway leaks a Server header"
grep -q "^/repos/test/site/statuses/rev-A Bearer test-token pending " "$STATUSES" || die "no pending status for A"
[[ "$(status_of A)" == "success | "* ]] || die "expected success status for A, got: $(status_of A)"
grep -q "smoke: got 'version A'" "$STATE_DIR/site.smoke.log" || die "smoke tests didn't run against the gateway"
pass "1. first run deploys A via the gateway on port $PORT; smoke tests pass; GitHub gets pending then success"

# 2 ── broken release
publish BROKEN 500
if update; then die "a broken image should make the run fail"; fi
[[ "$(served)" == "version A" ]] || die "after rollback expected version A, got: $(served)"
[[ -s "$STATE_DIR/site.known-bad" ]] || die "broken image was not recorded"
[[ "$(status_of BROKEN)" == "failure | Health check failed; staging rolled back to rev-A" ]] || die "wrong status: $(status_of BROKEN)"
pass "2. broken image detected, recorded and rolled back; A still serving; GitHub gets failure"

# 3 ── no retry loop
out="$(update 2>&1)" || die "run after rollback should succeed"
grep -q "failed its checks earlier" <<<"$out" || die "expected a known-bad skip, got: $out"
[[ "$(served)" == "version A" ]] || die "still expected version A"
pass "3. known-bad image is skipped, not redeployed every run"

# 4 ── fix released
publish B 200
update || die "fixed image should deploy"
[[ "$(served)" == "version B" ]] || die "expected version B, got: $(served)"
docker image inspect "$IMG:previous" >/dev/null || die "previous image not kept for manual rollback"
[[ "$(status_of B)" == "success | "* ]] || die "expected success status for B, got: $(status_of B)"
pass "4. fixed image B deployed; A kept as :previous"

# 5 ── nothing new
out="$(update 2>&1)" || die "idle run failed"
[[ -z "$out" ]] || die "idle run should be silent, got: $out"
pass "5. no new image → no restart, no log noise"

# 6 ── healthy, but its smoke tests fail
publish SMOKEFAIL 200
if update; then die "a smoke-test failure should make the run fail"; fi
[[ "$(served)" == "version B" ]] || die "after smoke failure expected version B, got: $(served)"
[[ "$(status_of SMOKEFAIL)" == "failure | Smoke tests failed; staging rolled back to rev-B" ]] || die "wrong status: $(status_of SMOKEFAIL)"
pass "6. smoke-test failure rolls back to B; GitHub gets failure"

# 7 ── no smoke-test image for this build
publish C 200 no-smoke
update || die "a missing smoke image should not fail the deploy"
[[ "$(served)" == "version C" ]] || die "expected version C, got: $(served)"
[[ "$(status_of C)" == "error | Live on staging, but smoke tests could not run"* ]] || die "wrong status: $(status_of C)"
pass "7. missing smoke image: C stays live, GitHub gets error"

echo "All updater scenarios passed."
