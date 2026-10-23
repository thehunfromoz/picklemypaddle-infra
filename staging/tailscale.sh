#!/usr/bin/env bash
# Reach staging over Tailscale with HTTPS, for club demos (SCRUM-38).
# Run through install.sh:
#
#   sudo ./staging/install.sh --tailscale       serve staging at https://<this machine>.<tailnet>.ts.net:8443
#                                               and the blog editor at ...:8444/keystatic (SCRUM-34)
#   sudo ./staging/install.sh --tailscale-off   stop serving both there (the LAN address keeps working)
#
# The editor's port forwards to the gateway's loopback-only listener, so Tailscale is the
# only way to reach the editor at all.
# Only devices on your tailnet can open the address. It never uses Funnel (public
# internet) and never touches the other Tailscale Serve settings on this machine
# (port 443 belongs to another app): it checks them before and after, and undoes
# its own change if anything else moved. Safe to re-run.
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_DIR="${STACK_DIR:-/opt/picklemypaddle/staging}"
ENV_FILE="$STACK_DIR/.env"
HELPER="$SRC_DIR/tailscale_serve.py"
MIN_VERSION="1.52" # first release with `tailscale serve --bg --https=<port> <target>`
VERIFY_TRIES="${VERIFY_TRIES:-12}" # the first certificate can take a few seconds
VERIFY_WAIT="${VERIFY_WAIT:-5}"

ok() { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
fail() { printf '  \033[31m✗\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\n%s\n' "$*"; }

case "${1:-}" in
  on | off) MODE="$1" ;;
  *) echo "usage: sudo ./staging/install.sh --tailscale | --tailscale-off" >&2; exit 2 ;;
esac
[[ $EUID -eq 0 || -n "${PMP_TEST:-}" ]] || fail "run with sudo"

env_get() { sed -n "s/^$1=//p" "$ENV_FILE" | tail -n1; }

# Set KEY=VALUE in the installed .env, keeping every other line as it is.
env_set() { # env_set <key> <value>
  python3 - "$ENV_FILE" "$1" "$2" <<'PY'
import sys
path, key, value = sys.argv[1:]
lines = open(path, encoding="utf-8").read().splitlines()
out, done = [], False
for line in lines:
    if line.startswith(key + "="):
        if not done:
            out.append(f"{key}={value}")
            done = True
        continue
    out.append(line)
if not done:
    out.append(f"{key}={value}")
open(path, "w", encoding="utf-8").write("\n".join(out) + "\n")
PY
}

serve_json() { tailscale serve status --json 2>/dev/null || echo '{}'; }

info "Pre-flight checks"
[[ -f "$ENV_FILE" ]] || fail "staging isn't installed yet; run: sudo ./staging/install.sh"
command -v tailscale >/dev/null || fail "tailscale is not installed on this machine"
command -v python3 >/dev/null || fail "python3 missing (apt install python3)"
version="$(tailscale version 2>/dev/null | head -n1)"
if [[ ! "$version" =~ ^([0-9]+)\.([0-9]+) ]] ||
  (( BASH_REMATCH[1] * 1000 + BASH_REMATCH[2] < 1052 )); then
  fail "Tailscale $version is too old (need $MIN_VERSION or newer); update: sudo apt update && sudo apt install tailscale"
fi
ok "Tailscale $version"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
tailscale status --json >"$tmp/status.json" 2>/dev/null || fail "can't read Tailscale status; is tailscaled running?"
host="$(python3 "$HELPER" dnsname "$tmp/status.json")" || exit 1
ok "this machine is $host on your tailnet"

PORT="$(env_get STAGING_PORT)"; PORT="${PORT:-8088}"
TS_PORT="$(env_get TAILSCALE_HTTPS_PORT)"; TS_PORT="${TS_PORT:-8443}"
[[ "$TS_PORT" =~ ^[0-9]+$ && "$TS_PORT" != 443 ]] || fail "TAILSCALE_HTTPS_PORT must be a port number other than 443 (443 is another app's)"
ED_LOCAL="$(env_get EDITOR_LOCAL_PORT)"; ED_LOCAL="${ED_LOCAL:-8089}"
ED_PORT="$(env_get TAILSCALE_EDITOR_HTTPS_PORT)"; ED_PORT="${ED_PORT:-8444}"
[[ "$ED_PORT" =~ ^[0-9]+$ && "$ED_PORT" != 443 && "$ED_PORT" != "$TS_PORT" ]] ||
  fail "TAILSCALE_EDITOR_HTTPS_PORT must be a port number other than 443 and $TS_PORT"
target="http://127.0.0.1:$PORT"
ts_url="https://$host:$TS_PORT"
lan_url="http://home-server:$PORT"
ed_target="http://127.0.0.1:$ED_LOCAL"
ed_url="https://$host:$ED_PORT"

serve_json >"$tmp/before.json"
others="$(python3 - "$tmp/before.json" "$host" "$TS_PORT" "$ED_PORT" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1])) or {}
skip = {f"{sys.argv[2]}:{p}" for p in sys.argv[3:]}
print(", ".join(sorted(k for k in (cfg.get("Web") or {}) if k not in skip)) or "none")
PY
)"
ok "existing Tailscale Serve settings (left untouched): $others"

restart_integrations() {
  docker compose --project-directory "$STACK_DIR" -f "$STACK_DIR/compose.staging.yml" \
    up -d --pull never --no-deps integrations >/dev/null
}

# Stop serving one port, if it is ours. Never touches a port something else holds.
unserve() { # unserve <port> <target> <name>
  local held
  serve_json >"$tmp/before.json"
  held="$(python3 "$HELPER" state "$tmp/before.json" "$host" "$1" "$2")"
  if [[ "$held" == free ]]; then
    ok "port $1 wasn't being served"
  elif [[ "$held" == other ]]; then
    fail "port $1 is served by something other than $3; not touching it (check: tailscale serve status)"
  else
    tailscale serve --https="$1" off >/dev/null || fail "tailscale serve --https=$1 off failed"
    serve_json >"$tmp/after.json"
    python3 "$HELPER" verify-off "$tmp/before.json" "$tmp/after.json" "$host" "$1" || fail "see above"
    ok "https://$host:$1 ($3) no longer answers; other Serve settings unchanged"
  fi
}

if [[ "$MODE" == off ]]; then
  info "Turning off staging over Tailscale"
  unserve "$ED_PORT" "$ed_target" "the blog editor"
  unserve "$TS_PORT" "$target" staging
  origins="$(env_get STAGING_SITE_ORIGINS)"
  origins="$(tr ',' '\n' <<<"${origins:-$lan_url}" | grep -vx "$ts_url" | grep . | paste -sd, -)"
  env_set STAGING_SITE_ORIGINS "${origins:-$lan_url}"
  env_set STAGING_PUBLIC_URL "$lan_url"
  restart_integrations
  ok "GitHub status links point to $lan_url again"
  info "Done. Staging is still on the LAN at $lan_url."
  exit 0
fi

info "Serving staging at $ts_url"
curl -fsS --max-time 5 "$target/healthz" >/dev/null || fail "staging isn't answering on $target; check: sudo systemctl status pmp-staging-update"
# Serve one port over HTTPS on the tailnet. Refuses a port something else holds or that has
# Funnel on, and undoes its own change if anything else in Serve moved.
serve() { # serve <port> <target> <name>
  local plan
  serve_json >"$tmp/before.json"
  plan="$(python3 "$HELPER" check "$tmp/before.json" "$host" "$1" "$2")" || exit 1
  if [[ "$plan" == already ]]; then
    ok "$3: already set up"
    return 0
  fi
  if ! tailscale serve --bg --https="$1" "$2" >"$tmp/serve.log" 2>&1; then
    sed 's/^/    /' "$tmp/serve.log" >&2
    fail "tailscale serve failed. If it mentions HTTPS or certificates: Tailscale admin console → DNS → enable HTTPS Certificates, then re-run"
  fi
  serve_json >"$tmp/after.json"
  if ! python3 "$HELPER" verify "$tmp/before.json" "$tmp/after.json" "$host" "$1" "$2"; then
    tailscale serve --https="$1" off >/dev/null 2>&1 || true
    fail "undid the change (see above); nothing else was touched"
  fi
  ok "Tailscale Serve: https://$host:$1 → $2 ($3; tailnet only, no Funnel)"
}

# Check both ports, and that the editor answers locally, before changing anything.
curl -fsS --max-time 5 -o /dev/null "$ed_target/keystatic" ||
  fail "the blog editor isn't answering on $ed_target; re-run: sudo ./staging/install.sh"
python3 "$HELPER" check "$tmp/before.json" "$host" "$TS_PORT" "$target" >/dev/null || exit 1
python3 "$HELPER" check "$tmp/before.json" "$host" "$ED_PORT" "$ed_target" >/dev/null || exit 1
serve "$TS_PORT" "$target" staging
serve "$ED_PORT" "$ed_target" "the blog editor"

origins="$(env_get STAGING_SITE_ORIGINS)"
origins="$( { tr ',' '\n' <<<"${origins:-$lan_url}"; echo "$ts_url"; } | grep . | awk '!seen[$0]++' | paste -sd, -)"
env_set STAGING_SITE_ORIGINS "$origins"
env_set STAGING_PUBLIC_URL "$ts_url"
restart_integrations
ok "staging accepts both addresses ($origins); GitHub status links → $ts_url"

info "Checking it through Tailscale (with a real certificate check)"
for ((i = 1; ; i++)); do
  curl -fsS --max-time 10 "$ts_url/healthz" >/dev/null 2>&1 && break
  (( i < VERIFY_TRIES )) || fail "$ts_url didn't answer; check: tailscale serve status"
  sleep "$VERIFY_WAIT"
done
ok "$ts_url answers with a valid HTTPS certificate"
headers="$(curl -fsS --max-time 10 -D - -o /dev/null "$ts_url/")"
grep -qi '^x-robots-tag: noindex' <<<"$headers" || fail "pages aren't marked noindex; re-apply the gateway: sudo ./staging/install.sh"
grep -qi "^content-security-policy: default-src 'self'" <<<"$headers" || fail "the site's security headers are missing through Tailscale"
ok "noindex and security headers present"
curl -fsS --max-time 10 "$ts_url/env.css" | grep -q 'data-env="staging-only"' || fail "/env.css isn't the staging one; re-apply the gateway: sudo ./staging/install.sh"
ok "Preview ribbon switched on"
cors_ok=false
for ((i = 1; i <= VERIFY_TRIES; i++)); do
  cors="$(curl -fsS --max-time 10 -D - -o /dev/null -H "Origin: $ts_url" "$ts_url/api/status" 2>/dev/null || true)"
  if grep -qi "^access-control-allow-origin: $ts_url" <<<"$cors"; then cors_ok=true; break; fi
  sleep "$VERIFY_WAIT"
done
if $cors_ok; then
  ok "/api accepts calls from $ts_url"
else
  warn "/api doesn't accept $ts_url yet. The integrations image may predate SCRUM-38 (comma-separated origins); it picks this up after its next update"
fi
curl -fsS --max-time 10 -o /dev/null "$ed_url/keystatic" || fail "$ed_url/keystatic didn't answer; check: tailscale serve status"
ok "blog editor answers at $ed_url/keystatic (Tailscale only)"

info "Done. Open $ts_url on any device signed in to your tailnet.
Blog editor: $ed_url/keystatic
Phone or iPad setup, the club-demo checklist and how to switch it off:
  runbooks/staging-home-server.md → \"Club demos over Tailscale\""
