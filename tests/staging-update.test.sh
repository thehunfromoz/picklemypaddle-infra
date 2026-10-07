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
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
REG="localhost:5000"
IMG="$REG/pmp-test/site"
PORT=18088
export STACK_DIR="$WORK/stack" STATE_DIR="$WORK/state" HEALTH_TIMEOUT=60

pass() { printf '\033[32mPASS\033[0m %s\n' "$*"; }
die() {
  printf '\033[31mFAIL\033[0m %s\n' "$*" >&2
  docker compose --project-directory "$STACK_DIR" -f "$STACK_DIR/compose.staging.yml" ps -a >&2 || true
  exit 1
}
cleanup() {
  docker compose --project-directory "$STACK_DIR" -f "$STACK_DIR/compose.staging.yml" down -v >/dev/null 2>&1 || true
  docker rm -f pmp-test-registry >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

publish() { # publish <version> <health-status>
  docker build -q -t "$IMG:staging" --build-arg VERSION="$1" --build-arg HEALTH="$2" "$ROOT/tests/fixtures" >/dev/null
  docker push -q "$IMG:staging" >/dev/null
  docker rmi "$IMG:staging" >/dev/null # make the updater really pull it
}
served() { curl -fsS "http://127.0.0.1:$PORT/" 2>/dev/null || echo "(no answer)"; }
update() { "$STACK_DIR/update.sh"; }

docker run -d --name pmp-test-registry -p 5000:5000 registry:2 >/dev/null
mkdir -p "$STACK_DIR/gateway"
cp "$ROOT/staging/compose.staging.yml" "$ROOT/staging/update.sh" "$STACK_DIR/"
cp "$ROOT/staging/gateway/Caddyfile" "$STACK_DIR/gateway/"
sed -e "s|^STAGING_PORT=.*|STAGING_PORT=$PORT|" \
    -e "s|^STAGING_BIND=.*|STAGING_BIND=127.0.0.1|" \
    -e "s|^SITE_IMAGE=.*|SITE_IMAGE=$IMG:staging|" \
    -e "s|^HEALTH_TIMEOUT=.*|HEALTH_TIMEOUT=60|" \
    "$ROOT/staging/.env.example" >"$STACK_DIR/.env"
sleep 2

# 1 ── first deploy
publish A 200
update || die "first run should succeed"
[[ "$(served)" == "version A" ]] || die "expected version A, got: $(served)"
[[ "$(curl -fsS "http://127.0.0.1:$PORT/healthz")" == "health 200" ]] || die "/healthz not routed to the site"
curl -fsSI "http://127.0.0.1:$PORT/" | grep -qi '^server:' && die "gateway leaks a Server header"
pass "1. first run deploys A through the gateway on port $PORT"

# 2 ── broken release
publish BROKEN 500
if update; then die "a broken image should make the run fail"; fi
[[ "$(served)" == "version A" ]] || die "after rollback expected version A, got: $(served)"
[[ -s "$STATE_DIR/site.known-bad" ]] || die "broken image was not recorded"
pass "2. broken image detected, recorded and rolled back; A still serving"

# 3 ── no retry loop
out="$(update 2>&1)" || die "run after rollback should succeed"
grep -q "failed its health check earlier" <<<"$out" || die "expected a known-bad skip, got: $out"
[[ "$(served)" == "version A" ]] || die "still expected version A"
pass "3. known-bad image is skipped, not redeployed every run"

# 4 ── fix released
publish B 200
update || die "fixed image should deploy"
[[ "$(served)" == "version B" ]] || die "expected version B, got: $(served)"
docker image inspect "$IMG:previous" >/dev/null || die "previous image not kept for manual rollback"
pass "4. fixed image B deployed; A kept as :previous"

# 5 ── nothing new
out="$(update 2>&1)" || die "idle run failed"
[[ -z "$out" ]] || die "idle run should be silent, got: $out"
pass "5. no new image → no restart, no log noise"

echo "All updater scenarios passed."
