#!/usr/bin/env bash
# Tests for install.sh --tailscale / --tailscale-off (SCRUM-38), with stand-in
# `tailscale`, `curl` and `docker` commands, so they run in CI without a tailnet.
#
#   1. turning it on adds https://<host>:8443 → staging, leaves :443 alone, updates .env
#   2. running it again changes nothing
#   3. it never calls Funnel, never touches :443, never resets Serve
#   4. a port already used by something else is refused, nothing changes
#   5. Funnel already on for the port is refused
#   6. an old Tailscale is refused
#   7. a Serve change that moves anything else is undone
#   8. turning it off removes only staging's port and restores .env
#   9. turning it off refuses to remove a port staging doesn't own
#  10. the blog editor's port (SCRUM-34) taken by something else: refused before any change
#  11. the order admin's port (SCRUM-71) taken by something else: refused before any change
#  12. the admin answers but no login is set yet: a warning, not a failure; an unexpected answer fails
#  13. the gateway's admin listener isn't up (old install): refused before any change
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
HOST="home-server.tail8bc7ae.ts.net"
TS_URL="https://$HOST:8443"
ED_URL="https://$HOST:8444"
AD_URL="https://$HOST:8445"

pass() { printf '  \033[32m✓\033[0m %s\n' "$*"; }
die() { printf '  \033[31m✗\033[0m %s\n' "$*" >&2; [[ -f "$WORK/out" ]] && sed 's/^/    | /' "$WORK/out" >&2; exit 1; }

mkdir -p "$WORK/bin" "$WORK/stack"
export FAKE_DIR="$WORK" PATH="$WORK/bin:$PATH" PMP_TEST=1 STACK_DIR="$WORK/stack" VERIFY_TRIES=2 VERIFY_WAIT=0

# ── stand-ins ──────────────────────────────────────────────────────────────────
cat >"$WORK/bin/tailscale" <<'PY'
#!/usr/bin/env python3
"""Fake tailscale: keeps the Serve config in $FAKE_DIR/serve.json, logs every call."""
import json, os, sys
d = os.environ["FAKE_DIR"]
host = "home-server.tail8bc7ae.ts.net"
args = sys.argv[1:]
open(f"{d}/tailscale.log", "a").write(" ".join(args) + "\n")
path = f"{d}/serve.json"
cfg = json.load(open(path)) if os.path.exists(path) else {}
def save():
    json.dump(cfg, open(path, "w"))
if args == ["version"]:
    print(os.environ.get("FAKE_TS_VERSION", "1.88.1")); print("  tailscale commit: x")
elif args == ["status", "--json"]:
    print(json.dumps({"BackendState": "Running", "Self": {"DNSName": host + "."}}))
elif args == ["serve", "status", "--json"]:
    print(json.dumps(cfg))
elif args[:1] == ["serve"] and args[-1] == "off":
    port = args[1].split("=")[1]
    cfg.get("TCP", {}).pop(port, None); cfg.get("Web", {}).pop(f"{host}:{port}", None)
    save()
elif args[:2] == ["serve", "--bg"]:
    port, target = args[2].split("=")[1], args[3]
    cfg.setdefault("TCP", {})[port] = {"HTTPS": True}
    cfg.setdefault("Web", {})[f"{host}:{port}"] = {"Handlers": {"/": {"Proxy": target}}}
    if os.environ.get("FAKE_SERVE_CLOBBERS_443"):
        cfg["Web"][f"{host}:443"] = {"Handlers": {"/": {"Proxy": target}}}
    save()
else:
    sys.exit(f"fake tailscale: unexpected {args}")
PY

cat >"$WORK/bin/curl" <<'PY'
#!/usr/bin/env python3
"""Fake curl: staging answers on 127.0.0.1; the tailnet URL answers only while Serve has it."""
import json, os, sys
d = os.environ["FAKE_DIR"]
args = sys.argv[1:]
url = [a for a in args if a.startswith("http")][-1]
origin = next((args[i + 1][8:] for i, a in enumerate(args) if a == "-H" and args[i + 1].startswith("Origin: ")), None)
if url.startswith("https://"):
    cfg = json.load(open(f"{d}/serve.json")) if os.path.exists(f"{d}/serve.json") else {}
    port = url.split("/")[2].rsplit(":", 1)[1]
    if port not in cfg.get("TCP", {}):
        sys.exit(7)
path = "/" + url.split("/", 3)[3] if url.count("/") >= 3 else "/"
if path.startswith("/admin") and "-w" in args:
    # The order admin through Serve (SCRUM-71): FAKE_ADMIN_CODE stands in for integrations' answer.
    print(os.environ.get("FAKE_ADMIN_CODE", "200"), end="")
elif path == "/gateway-healthz" and url.startswith("http://127.0.0.1:8100") and os.environ.get("FAKE_ADMIN_DOWN"):
    sys.exit(7)
elif "-D" in args:
    if path == "/api/status":
        print(f"HTTP/2 200\naccess-control-allow-origin: {origin}" if os.environ.get("FAKE_CORS", "ok") == "ok" else "HTTP/2 200")
    else:
        print("HTTP/2 200\nx-robots-tag: noindex, nofollow\ncontent-security-policy: default-src 'self'")
elif path == "/env.css":
    print('[data-env="staging-only"][hidden] { display: block !important; }')
else:
    print("ok")
PY

cat >"$WORK/bin/docker" <<'SH'
#!/bin/sh
echo "$*" >>"$FAKE_DIR/docker.log"
SH
chmod +x "$WORK/bin/"*

reset() { # reset [serve-json]
  rm -f "$WORK"/*.log
  printf '%s' "${1:-}" >"$WORK/serve.json"
  cp "$ROOT/staging/.env.example" "$STACK_DIR/.env"
  # An existing install (before SCRUM-38) has no STAGING_SITE_ORIGINS line yet.
  sed -i '/^STAGING_SITE_ORIGINS=/d' "$STACK_DIR/.env"
}
run() { "$ROOT/staging/install.sh" "$@" >"$WORK/out" 2>&1; }
env_val() { sed -n "s/^$1=//p" "$STACK_DIR/.env"; }
OTHER_APP="{\"TCP\":{\"443\":{\"HTTPS\":true}},\"Web\":{\"$HOST:443\":{\"Handlers\":{\"/\":{\"Proxy\":\"http://localhost:3000\"}}}}}"
other_app_untouched() {
  python3 - "$WORK/serve.json" "$HOST" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1])); host = sys.argv[2]
assert cfg["TCP"]["443"] == {"HTTPS": True}, cfg
assert cfg["Web"][f"{host}:443"] == {"Handlers": {"/": {"Proxy": "http://localhost:3000"}}}, cfg
assert not cfg.get("AllowFunnel"), cfg
PY
}

echo "install.sh --tailscale"

# 1 ── on
reset "$OTHER_APP"
run --tailscale || die "1. --tailscale failed"
other_app_untouched || die "1. the :443 app changed"
grep -q '"8443": {"HTTPS": true}' "$WORK/serve.json" || die "1. :8443 not served over HTTPS"
grep -q "\"$HOST:8443\": {\"Handlers\": {\"/\": {\"Proxy\": \"http://127.0.0.1:8088\"}}}" "$WORK/serve.json" || die "1. :8443 doesn't point at staging"
grep -q '"8444": {"HTTPS": true}' "$WORK/serve.json" || die "1. :8444 (editor) not served over HTTPS"
grep -q "\"$HOST:8444\": {\"Handlers\": {\"/\": {\"Proxy\": \"http://127.0.0.1:8101\"}}}" "$WORK/serve.json" || die "1. :8444 doesn't point at the editor's loopback listener"
grep -q "blog editor answers at $ED_URL/keystatic" "$WORK/out" || die "1. editor not confirmed over Tailscale"
grep -q '"8445": {"HTTPS": true}' "$WORK/serve.json" || die "1. :8445 (admin) not served over HTTPS"
grep -q "\"$HOST:8445\": {\"Handlers\": {\"/\": {\"Proxy\": \"http://127.0.0.1:8100\"}}}" "$WORK/serve.json" || die "1. :8445 doesn't point at the admin's loopback listener"
grep -q "order admin answers at $AD_URL/admin and lets your Tailscale login in" "$WORK/out" || die "1. admin not confirmed over Tailscale"
[[ "$(env_val STAGING_PUBLIC_URL)" == "$TS_URL" ]] || die "1. STAGING_PUBLIC_URL not switched"
[[ "$(env_val STAGING_SITE_ORIGINS)" == "http://home-server:8088,$TS_URL" ]] || die "1. origins: $(env_val STAGING_SITE_ORIGINS)"
grep -q "up -d --pull never --no-deps integrations" "$WORK/docker.log" || die "1. integrations not restarted"
grep -q "/api accepts calls from $TS_URL" "$WORK/out" || die "1. CORS not confirmed"
pass "1. serves $TS_URL → staging, $ED_URL → editor and $AD_URL → admin (loopback), :443 untouched, .env updated, integrations restarted"

# 2 ── again
before="$(cat "$WORK/serve.json")"; env_before="$(cat "$STACK_DIR/.env")"
rm -f "$WORK/tailscale.log"
run --tailscale || die "2. re-run failed"
grep -q "already set up" "$WORK/out" || die "2. didn't notice it was already set up"
! grep -q -- "--bg" "$WORK/tailscale.log" || die "2. re-applied Serve"
[[ "$(cat "$WORK/serve.json")" == "$before" && "$(cat "$STACK_DIR/.env")" == "$env_before" ]] || die "2. something changed"
pass "2. running it again changes nothing"

# 3 ── never funnel / 443 / reset (across every call so far)
reset "$OTHER_APP"; run --tailscale; run --tailscale-off; run --tailscale
if grep -Eq 'funnel|--https=443|reset' "$WORK/tailscale.log"; then die "3. forbidden call: $(grep -E 'funnel|--https=443|reset' "$WORK/tailscale.log")"; fi
pass "3. never calls Funnel, never touches :443, never resets Serve"

# 4 ── port taken by something else
taken="{\"TCP\":{\"8443\":{\"HTTPS\":true}},\"Web\":{\"$HOST:8443\":{\"Handlers\":{\"/\":{\"Proxy\":\"http://127.0.0.1:9999\"}}}}}"
reset "$taken"
! run --tailscale || die "4. accepted a port in use"
grep -q "already served by Tailscale" "$WORK/out" || die "4. unclear message"
[[ "$(cat "$WORK/serve.json")" == "$taken" && "$(env_val STAGING_PUBLIC_URL)" == "http://home-server:8088" ]] || die "4. changed something"
pass "4. refuses a port already in use; nothing changed"

# 5 ── funnel already on for the port
reset "{\"AllowFunnel\":{\"$HOST:8443\":true}}"
! run --tailscale || die "5. accepted Funnel"
grep -q "Funnel" "$WORK/out" || die "5. unclear message"
pass "5. refuses when Funnel is on for the port"

# 6 ── old tailscale
reset "$OTHER_APP"
! FAKE_TS_VERSION=1.50.1 run --tailscale || die "6. accepted Tailscale 1.50"
grep -q "too old" "$WORK/out" || die "6. unclear message"
pass "6. refuses Tailscale older than 1.52"

# 7 ── Serve moved something else → undone
reset "$OTHER_APP"
! FAKE_SERVE_CLOBBERS_443=1 run --tailscale || die "7. accepted a change to :443"
grep -q "other than staging's port changed" "$WORK/out" || die "7. unclear message"
grep -q -- "--https=8443 off" "$WORK/tailscale.log" || die "7. didn't undo its own change"
[[ "$(env_val STAGING_PUBLIC_URL)" == "http://home-server:8088" ]] || die "7. .env changed"
pass "7. undoes the change if anything else moved"

# 8 ── off
reset "$OTHER_APP"; run --tailscale
run --tailscale-off || die "8. --tailscale-off failed"
other_app_untouched || die "8. the :443 app changed"
! grep -q '"8443"' "$WORK/serve.json" || die "8. :8443 still served"
! grep -q '"8444"' "$WORK/serve.json" || die "8. :8444 (editor) still served"
! grep -q '"8445"' "$WORK/serve.json" || die "8. :8445 (admin) still served"
[[ "$(env_val STAGING_PUBLIC_URL)" == "http://home-server:8088" ]] || die "8. STAGING_PUBLIC_URL not restored"
[[ "$(env_val STAGING_SITE_ORIGINS)" == "http://home-server:8088" ]] || die "8. origins: $(env_val STAGING_SITE_ORIGINS)"
run --tailscale-off || die "8. second --tailscale-off failed"
grep -q "wasn't being served" "$WORK/out" || die "8. second run unclear"
pass "8. turning it off removes only staging's port and restores .env (and is safe to repeat)"

# 9 ── off refuses someone else's port
reset "$taken"
! run --tailscale-off || die "9. removed a port staging doesn't own"
[[ "$(cat "$WORK/serve.json")" == "$taken" ]] || die "9. changed Serve"
pass "9. turning it off leaves a port it doesn't own alone"

# 10 ── the editor's port is someone else's: refused before staging's port is touched
ed_taken="{\"TCP\":{\"8444\":{\"HTTPS\":true}},\"Web\":{\"$HOST:8444\":{\"Handlers\":{\"/\":{\"Proxy\":\"http://127.0.0.1:9999\"}}}}}"
reset "$ed_taken"
! run --tailscale || die "10. accepted an editor port in use"
grep -q "already served by Tailscale" "$WORK/out" || die "10. unclear message"
[[ "$(cat "$WORK/serve.json")" == "$ed_taken" ]] || die "10. changed Serve (staging's port must not be added first)"
[[ "$(env_val STAGING_PUBLIC_URL)" == "http://home-server:8088" ]] || die "10. .env changed"
pass "10. refuses an editor port already in use, before changing anything"

# 11 ── the admin's port is someone else's: refused before anything is served
ad_taken="{\"TCP\":{\"8445\":{\"HTTPS\":true}},\"Web\":{\"$HOST:8445\":{\"Handlers\":{\"/\":{\"Proxy\":\"http://127.0.0.1:9999\"}}}}}"
reset "$ad_taken"
! run --tailscale || die "11. accepted an admin port in use"
grep -q "already served by Tailscale" "$WORK/out" || die "11. unclear message"
[[ "$(cat "$WORK/serve.json")" == "$ad_taken" ]] || die "11. changed Serve (no port may be added first)"
[[ "$(env_val STAGING_PUBLIC_URL)" == "http://home-server:8088" ]] || die "11. .env changed"
pass "11. refuses an admin port already in use, before changing anything"

# 12 ── the admin's answer through Tailscale
reset "$OTHER_APP"
FAKE_ADMIN_CODE=503 run --tailscale || die "12. failed when no admin login is set yet"
grep -q "no one may sign in yet: sudo ./staging/install.sh --set-admin-logins" "$WORK/out" || die "12. no hint to set the admin logins"
reset "$OTHER_APP"
FAKE_ADMIN_CODE=502 run --tailscale || die "12. failed on an integrations image without the admin"
grep -q "predates SCRUM-71" "$WORK/out" || die "12. no hint about the old integrations image"
reset "$OTHER_APP"
! FAKE_ADMIN_CODE=000 run --tailscale || die "12. accepted an admin that doesn't answer"
pass "12. warns when no admin login is set or the image is old; fails when the admin doesn't answer"

# 13 ── the gateway's admin listener isn't there yet (staging not re-installed)
reset "$OTHER_APP"
! FAKE_ADMIN_DOWN=1 run --tailscale || die "13. went ahead without the admin listener"
grep -q "admin listener isn't answering" "$WORK/out" || die "13. unclear message"
other_app_untouched || die "13. the :443 app changed"
! grep -q '"8443"' "$WORK/serve.json" || die "13. served staging before checking the admin listener"
pass "13. refuses before changing anything when the admin listener isn't up"
