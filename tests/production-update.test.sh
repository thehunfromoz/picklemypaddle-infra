#!/usr/bin/env bash
# Integration test for production/install.sh and production/update.sh (SCRUM-19), run in CI
# on a throwaway Docker host. A local registry and stand-in site images play GHCR and the
# releases. The gateway runs the real production Caddyfile for "localhost" (Caddy's own
# internal CA), so the redirects, the 503 page and the live-site checks run for real.
#
#   0. install: gateway up, HTTPS on www and the bare domain, redirects, 503 page without a site
#   1. a first deploy that fails its checks stops the site; visitors still get the 503 page
#   2. deploying without --yes and without a terminal asks, and changes nothing
#   3. only release tags are accepted (not :staging, not a commit tag); unpublished ones fail
#   4. a good release deploys, is recorded in .env, and carries the HSTS setting
#   5. an unhealthy release is rolled back
#   6. a release built with the staging address is rolled back by the live-site checks
#   7. a second good release deploys; the first becomes the rollback target
#   8. rollback goes back to it; deploying what already runs does nothing
#   9. check and status work; production has no auto-update timer or label
#  10. re-installing leaves an unchanged site alone and applies an .env change (HSTS)
#  11. a second website's file in gateway/sites/ is served next to Pickle My Paddle, and
#      removing it takes it away again, without touching the running site
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
REG="localhost:5000"
IMG="$REG/pmp-test/site"
export STACK_DIR="$WORK/stack" DEST_DIR="$WORK/stack" STATE_DIR="$WORK/state"
export PMP_TEST=1 PMP_CURL_OPTS=-k HEALTH_TIMEOUT=60 VERIFY_TRIES=3 VERIFY_WAIT=1 CERT_WAIT=90

pass() { printf '\033[32mPASS\033[0m %s\n' "$*"; }
die() {
  printf '\033[31mFAIL\033[0m %s\n' "$*" >&2
  local out
  out="$(docker ps -a --format '{{.Names}} {{.Status}}'
    docker compose --project-directory "$STACK_DIR" -f "$STACK_DIR/compose.production.yml" logs --tail 15 2>&1 || true
    [[ -f "$WORK/out" ]] && { echo '--- last command output'; tail -n 25 "$WORK/out"; })"
  echo "$out" >&2
  # Also as a GitHub annotation, so the failure is readable from the API.
  [[ -n "${GITHUB_ACTIONS:-}" ]] && echo "::error title=${1:0:80}::${out//$'\n'/%0A}"
  exit 1
}
cleanup() {
  docker compose --project-directory "$STACK_DIR" -f "$STACK_DIR/compose.production.yml" down -v >/dev/null 2>&1 || true
  docker rm -f pmp-test-registry >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT
trap 'die "unexpected failure at line $LINENO"' ERR

publish() { # publish <tag> <health-status> [baked-origin] [sitemap-path]
  docker build -q -t "$IMG:$1" -f "$ROOT/tests/fixtures/prod-site.Dockerfile" \
    --build-arg VERSION="rev-$1" --build-arg HEALTH="$2" --build-arg ORIGIN="${3:-https://www.picklemypaddle.com}" --build-arg SITEMAP="${4:-/sitemap.xml}" \
    --label org.opencontainers.image.revision="rev-$1" \
    --label org.opencontainers.image.source=https://github.com/test/site \
    "$ROOT/tests/fixtures" >/dev/null
  docker push -q "$IMG:$1" >/dev/null
  docker rmi "$IMG:$1" >/dev/null || true # make update.sh really pull it
}
get() { curl -sk --max-time 10 --resolve www.localhost:443:127.0.0.1 "$@"; }
served() { get https://www.localhost/ 2>/dev/null || echo "(no answer)"; }
status_code() { get -o /dev/null -w '%{http_code}' https://www.localhost/ || true; }
pinned() { sed -n 's/^SITE_VERSION=//p' "$STACK_DIR/.env"; }
site_running() { docker ps -q --filter label=com.docker.compose.project=pmp-production --filter label=com.docker.compose.service=site; }
update() { "$STACK_DIR/update.sh" "$@" >"$WORK/out" 2>&1; }

docker run -d --name pmp-test-registry -p 5000:5000 registry:2 >/dev/null
mkdir -p "$STACK_DIR"
sed -e 's|^SITE_DOMAIN=.*|SITE_DOMAIN=localhost|' \
  -e "s|^SITE_IMAGE_REPO=.*|SITE_IMAGE_REPO=$IMG|" \
  -e 's|^HEALTH_TIMEOUT=.*|HEALTH_TIMEOUT=60|' \
  "$ROOT/production/.env.example" >"$STACK_DIR/.env"
sleep 2

# 0 ── install
bash "$ROOT/production/install.sh" >"$WORK/out" 2>&1 || die "install.sh failed"
grep -q "no site release is deployed yet" "$WORK/out" || die "install.sh should say no release is deployed yet"
[[ "$(get https://www.localhost/gateway-healthz)" == ok ]] || die "gateway health route not answering over HTTPS"
[[ "$(status_code)" == 503 ]] || die "expected a 503 page while no site is deployed, got $(status_code)"
get -D - -o /dev/null https://www.localhost/ | grep -qi '^x-robots-tag: noindex' || die "the 503 page should say noindex"
[[ "$(get -o /dev/null -w '%{redirect_url}' 'https://localhost/p?x=1')" == "https://www.localhost/p?x=1" ]] || die "bare domain should redirect to www"
[[ "$(curl -s -o /dev/null -w '%{http_code}' --resolve www.localhost:80:127.0.0.1 http://www.localhost/)" == 308 ]] || die "http should redirect to https"
[[ -z "$(site_running)" ]] || die "install.sh must not start the site"
bash "$ROOT/production/install.sh" >"$WORK/out" 2>&1 || die "re-running install.sh failed"
grep -q "kept existing .env" "$WORK/out" || die "re-install should keep .env"
pass "0. install: HTTPS on www and the bare domain, redirects, 503 page, no site started; re-install is safe"

# 1 ── a first deploy that fails leaves visitors on the 503 page
publish v0.9.0 500
if update deploy v0.9.0 --yes; then die "an unhealthy first release should fail"; fi
grep -q "site is stopped" "$WORK/out" || die "expected the 'site is stopped' message"
[[ "$(status_code)" == 503 ]] || die "after a failed first deploy visitors should get the 503 page, got $(status_code)"
[[ -z "$(pinned)" ]] || die "a failed deploy must not be recorded in .env, got '$(pinned)'"
[[ -z "$(site_running)" ]] || die "the failed first release should have been removed"
pass "1. failed first deploy: site stopped, 503 page, nothing recorded"

# 2 ── no --yes and no terminal
# v1.0.0 stands for a release from before SCRUM-36: its sitemap is /sitemap-index.xml.
publish v1.0.0 200 https://www.picklemypaddle.com /sitemap-index.xml
if update deploy v1.0.0 </dev/null; then die "deploying without --yes and without a terminal should refuse"; fi
grep -q -- "--yes" "$WORK/out" || die "expected the refusal to mention --yes"
[[ -z "$(site_running)" && -z "$(pinned)" ]] || die "refused deploy must change nothing"
pass "2. without --yes and a terminal, deploy refuses and changes nothing"

# 3 ── only releases
if update deploy staging --yes; then die "':staging' must be refused"; fi
grep -q "not a release version" "$WORK/out" || die "expected 'not a release version'"
if update deploy 0123456789abcdef0123456789abcdef01234567 --yes; then die "a commit tag must be refused"; fi
if update deploy v9.9.9 --yes; then die "an unpublished release must fail"; fi
grep -q "cannot pull" "$WORK/out" || die "expected 'cannot pull' for an unpublished release"
[[ -z "$(site_running)" ]] || die "refused versions must not start anything"
pass "3. :staging and commit tags are refused; an unpublished release fails to pull"

# 4 ── good release
update deploy v1.0.0 --yes || die "a good release should deploy"
[[ "$(served)" == *"version rev-v1.0.0"* ]] || die "expected v1.0.0, got: $(served)"
[[ "$(pinned)" == v1.0.0 ]] || die ".env should pin v1.0.0, got '$(pinned)'"
grep -q ' v1.0.0 rev-v1.0.0 ' "$STATE_DIR/site.deployed" || die "deploy not recorded"
[[ "$(get https://www.localhost/version.txt)" == rev-v1.0.0 ]] || die "version.txt wrong"
get -D - -o /dev/null https://www.localhost/ | grep -qi '^strict-transport-security: max-age=86400' || die "HSTS from .env should reach the site"
grep -q 'compare' "$WORK/out" && die "a first deploy has nothing to compare against"
pass "4. v1.0.0 deployed, pinned in .env, HSTS reaches the site"

# 5 ── unhealthy release
publish v1.1.0 500
if update deploy v1.1.0 --yes; then die "an unhealthy release should fail"; fi
[[ "$(served)" == *"version rev-v1.0.0"* ]] || die "after rollback expected v1.0.0, got: $(served)"
[[ "$(pinned)" == v1.0.0 ]] || die ".env must still pin v1.0.0, got '$(pinned)'"
grep -q ' v1.1.0 ' "$STATE_DIR/site.failed" || die "failure not recorded"
pass "5. unhealthy v1.1.0 rolled back; v1.0.0 still serving and pinned"

# 6 ── healthy, but built with the staging address
publish v1.2.0 200 http://home-server:8088
if update deploy v1.2.0 --yes; then die "a release with the staging address must fail the live checks"; fi
grep -q "home-server" "$WORK/out" || die "expected the failure to name home-server"
[[ "$(served)" == *"version rev-v1.0.0"* ]] || die "after rollback expected v1.0.0, got: $(served)"
pass "6. v1.2.0 (staging address baked in) rolled back by the live-site checks"

# 6b ── healthy, but no sitemap at either address
publish v1.2.1 200 https://www.picklemypaddle.com /not-a-sitemap.xml
if update deploy v1.2.1 --yes; then die "a release without a sitemap must fail the live checks"; fi
grep -q "sitemap" "$WORK/out" || die "expected the failure to name the sitemap"
[[ "$(served)" == *"version rev-v1.0.0"* ]] || die "after rollback expected v1.0.0, got: $(served)"
pass "6b. v1.2.1 (no /sitemap.xml) rolled back by the live-site checks"

# 7 ── second good release
publish v1.3.0 200
update deploy v1.3.0 --yes || die "a good release should deploy"
[[ "$(served)" == *"version rev-v1.3.0"* ]] || die "expected v1.3.0, got: $(served)"
[[ "$(pinned)" == v1.3.0 ]] || die ".env should pin v1.3.0"
[[ "$(cat "$STATE_DIR/site.previous-version")" == v1.0.0 ]] || die "previous release should be v1.0.0"
grep -q 'compare/rev-v1.0.0...rev-v1.3.0' "$WORK/out" || die "expected a GitHub compare link in the summary"
pass "7. v1.3.0 (serves /sitemap.xml, v1.0.0 the older /sitemap-index.xml) deployed; v1.0.0 remembered as the rollback target; compare link shown"

# 8 ── rollback, then a no-op
update rollback --yes || die "rollback should work"
[[ "$(served)" == *"version rev-v1.0.0"* ]] || die "after rollback expected v1.0.0, got: $(served)"
[[ "$(pinned)" == v1.0.0 ]] || die ".env should pin v1.0.0 after rollback"
[[ "$(cat "$STATE_DIR/site.previous-version")" == v1.3.0 ]] || die "after rollback the previous release should be v1.3.0"
update deploy v1.0.0 --yes || die "redeploying what runs should succeed"
grep -q "already running" "$WORK/out" || die "expected 'already running'"
pass "8. rollback returns to v1.0.0; deploying what already runs does nothing"

# 9 ── check, status, and nothing automatic
update check || die "check should pass on a healthy release"
update status || die "status should work"
grep -q 'v1.0.0' "$WORK/out" || die "status should show the running release"
[[ ! -d "$ROOT/production/systemd" ]] || die "production must not have an updater timer"
if grep -rq 'com.picklemypaddle.autoupdate' "$ROOT/production"; then die "production services must not carry the auto-update label"; fi
pass "9. check and status work; no timer, no auto-update label"

# 10 ── re-installing with a site running
before="$(site_running)"
bash "$ROOT/production/install.sh" >"$WORK/out" 2>&1 || die "re-install with a site running failed"
[[ "$(site_running)" == "$before" ]] || die "re-install must leave the running site container alone when nothing changed"
[[ "$(served)" == *"version rev-v1.0.0"* ]] || die "site should still serve v1.0.0 after re-install"
sed -i 's|^HSTS=.*|HSTS=max-age=3600|' "$STACK_DIR/.env"
bash "$ROOT/production/install.sh" >"$WORK/out" 2>&1 || die "re-install after an .env change failed"
get -D - -o /dev/null https://www.localhost/ | grep -qi '^strict-transport-security: max-age=3600' || die "an HSTS change in .env should reach the site after install.sh"
[[ "$(pinned)" == v1.0.0 ]] || die "install.sh must not change the pinned release"
pass "10. re-install leaves an unchanged site alone, applies an .env change, keeps the release"

# 11 ── a second website on the same gateway
SRC2="$WORK/src2"
cp -r "$ROOT/production" "$SRC2"
printf 'other.localhost {\n\trespond "other site" 200\n}\n' >"$SRC2/gateway/sites/other.caddy"
other() { curl -sk --max-time 10 --resolve other.localhost:443:127.0.0.1 https://other.localhost/ 2>/dev/null || echo "(no answer)"; }
[[ "$(other)" != "other site" ]] || die "other.localhost should not be served before its file is installed"
before="$(site_running)"
bash "$SRC2/install.sh" >"$WORK/out" 2>&1 || die "install with a second website failed"
[[ -f "$STACK_DIR/gateway/sites/other.caddy" ]] || die "the second website's file should be installed"
[[ "$(other)" == "other site" ]] || die "the second website should be served, got: $(other)"
[[ "$(served)" == *"version rev-v1.0.0"* ]] || die "Pickle My Paddle should keep serving v1.0.0 next to the second website"
[[ "$(site_running)" == "$before" ]] || die "adding a website must not restart the Pickle My Paddle site"
rm "$SRC2/gateway/sites/other.caddy"
bash "$SRC2/install.sh" >"$WORK/out" 2>&1 || die "install after removing the second website failed"
[[ ! -e "$STACK_DIR/gateway/sites/other.caddy" ]] || die "a website taken out of the checkout should be removed on install"
[[ "$(other)" != "other site" ]] || die "the removed website should no longer be served"
[[ "$(served)" == *"version rev-v1.0.0"* ]] || die "Pickle My Paddle should still serve v1.0.0"
pass "11. a second website is served next to Pickle My Paddle and can be taken away again"

echo "All production scenarios passed."
