#!/usr/bin/env bash
# Install or update the PickleMyPaddle production stack on the OVH VPS (SCRUM-19).
#
#   sudo ./production/install.sh           install, or apply changes from this checkout
#   sudo ./production/install.sh --check   only run the pre-flight checks
#
# What it does: checks the server, copies the stack to /opt/picklemypaddle/production,
# starts the gateway (Caddy asks Let's Encrypt for certificates on first start) and
# proves HTTPS works for the bare domain and www. It does NOT deploy the site: releases
# are deployed by hand with /opt/picklemypaddle/production/update.sh. Until the first
# release, visitors get the gateway's "temporarily unavailable" page.
#
# Several websites can share the gateway (gateway/sites/*.caddy). This script proves HTTPS for
# Pickle My Paddle only; check any other website yourself (runbook, "Adding another website").
#
# Safe to re-run: it keeps your .env, the certificates and the running site. You run it by
# hand after reviewing a change; nothing runs it automatically and it installs no timer.
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST_DIR="${DEST_DIR:-/opt/picklemypaddle/production}"
STATE_DIR="${STATE_DIR:-/var/lib/pmp-production}"
CERT_WAIT="${CERT_WAIT:-150}"
# Extra curl options for the HTTPS checks. Tests pass -k (their gateway uses Caddy's internal CA).
read -r -a CURL_OPTS <<<"${PMP_CURL_OPTS:-}"
CHECK_ONLY=false
case "${1:-}" in
  --check) CHECK_ONLY=true ;;
  "") ;;
  *)
    echo "usage: sudo $0 [--check]" >&2
    exit 2
    ;;
esac

ok() { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
fail() { printf '  \033[31m✗\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\n%s\n' "$*"; }

[[ $EUID -eq 0 || -n "${PMP_TEST:-}" ]] || fail "run with sudo"

compose() {
  docker compose --project-directory "$DEST_DIR" -f "$DEST_DIR/compose.production.yml" "$@"
}

# Settings: the installed .env if there is one, else the example.
ENV_FILE="$DEST_DIR/.env"
[[ -f "$ENV_FILE" ]] || ENV_FILE="$SRC_DIR/.env.example"
env_get() { # env_get <KEY>
  sed -n "s/^$1=//p" "$ENV_FILE" | tail -n1 | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/"
}
DOMAIN="$(env_get SITE_DOMAIN)"
DOMAIN="${DOMAIN:-picklemypaddle.com}"

info "Pre-flight checks"
command -v docker >/dev/null || fail "Docker is not installed"
docker info >/dev/null 2>&1 || fail "Docker daemon is not running"
docker compose version >/dev/null 2>&1 || fail "Docker Compose v2 plugin missing (apt install docker-compose-v2)"
ok "Docker $(docker version -f '{{.Server.Version}}'), $(docker compose version --short | sed 's/^/Compose /')"
for cmd in curl flock ss; do
  command -v "$cmd" >/dev/null || fail "$cmd missing (apt install curl util-linux iproute2)"
done
ok "curl, flock and ss present"

# Ports 80 and 443: free, or already held by this stack's own gateway (a re-install).
ours="$(docker ps --filter label=com.docker.compose.project=pmp-production \
  --filter label=com.docker.compose.service=gateway -q)"
for port in 80 443; do
  if ss -ltnH "sport = :$port" | grep -q .; then
    if [[ -n "$ours" ]]; then
      ok "port $port is held by the production gateway itself (re-install)"
    else
      ss -ltnpH "sport = :$port" >&2 || true
      fail "port $port is already used by something else; stop it first (it would stop Caddy getting certificates)"
    fi
  else
    ok "port $port is free"
  fi
done

# DNS: both names should point at this server, or Let's Encrypt can't validate them.
# Only a warning: DNS can be fixed while the gateway keeps retrying.
resolves_here() { # resolves_here <name>
  local name="$1" addrs mine a
  local -a found
  addrs="$(getent ahostsv4 "$name" 2>/dev/null | awk '{print $1}' | sort -u | xargs || true)"
  mine="$(ip -4 -o addr show 2>/dev/null | awk '{split($4, a, "/"); print a[1]}' | xargs || true)"
  if [[ -z "$addrs" ]]; then
    warn "$name does not resolve yet (Cloudflare: an A record for it, 'DNS only')"
    return 0
  fi
  read -r -a found <<<"$addrs"
  for a in "${found[@]}"; do
    if [[ " $mine " == *" $a "* ]]; then
      ok "$name -> $a (this server)"
      return 0
    fi
  done
  warn "$name resolves to $addrs, which is not an address on this server (${mine:-unknown}). Certificates are only issued when it points here (Cloudflare: 'DNS only', not proxied)"
}
resolves_here "$DOMAIN"
resolves_here "www.$DOMAIN"

if docker pull -q caddy:2-alpine >/dev/null 2>&1; then
  ok "can pull caddy:2-alpine"
else
  fail "cannot pull caddy:2-alpine (no internet, or Docker Hub is rate-limiting this server)"
fi

# Is what is installed in /opt the same as this checkout? (What runs is /opt, not the checkout.)
stale=""
for f in compose.production.yml update.sh; do
  cmp -s "$SRC_DIR/$f" "$DEST_DIR/$f" 2>/dev/null || stale="$stale $f"
done
# The gateway config is the Caddyfile plus one file per website in gateway/sites/.
diff -rq "$SRC_DIR/gateway" "$DEST_DIR/gateway" >/dev/null 2>&1 || stale="$stale gateway/"
if [[ -n "$stale" ]]; then
  printf '  \033[33m!\033[0m installed files differ from this checkout:%s\n    Apply them with: sudo %s\n' "$stale" "$0"
else
  ok "installed files match this checkout"
fi

if $CHECK_ONLY; then
  info "Checks passed. Nothing installed (--check)."
  exit 0
fi

info "Installing to $DEST_DIR"
install -d -m 0755 "$DEST_DIR" "$DEST_DIR/gateway" "$DEST_DIR/gateway/sites" "$STATE_DIR"
# A running gateway keeps its old config until it is recreated (the admin API that could
# reload it is switched off on purpose), so recreate it whenever the Caddyfile or any
# website's file changes, is added or is removed.
recreate=()
diff -rq "$SRC_DIR/gateway" "$DEST_DIR/gateway" >/dev/null 2>&1 || recreate=(--force-recreate)
install -m 0644 "$SRC_DIR/compose.production.yml" "$DEST_DIR/compose.production.yml"
install -m 0644 "$SRC_DIR/gateway/Caddyfile" "$DEST_DIR/gateway/Caddyfile"
# The checkout is the source of truth for which websites exist: copy its site files, and
# remove installed ones that are no longer in it (a website that was taken out).
for f in "$SRC_DIR"/gateway/sites/*; do
  [[ -f "$f" ]] && install -m 0644 "$f" "$DEST_DIR/gateway/sites/$(basename "$f")"
done
for f in "$DEST_DIR"/gateway/sites/*; do
  [[ -f "$f" && ! -e "$SRC_DIR/gateway/sites/$(basename "$f")" ]] && rm -f "$f"
done
install -m 0755 "$SRC_DIR/update.sh" "$DEST_DIR/update.sh"
if [[ -f "$DEST_DIR/.env" ]]; then
  ok "kept existing .env"
else
  install -m 0644 "$SRC_DIR/.env.example" "$DEST_DIR/.env"
  ok "created .env from .env.example"
fi
ENV_FILE="$DEST_DIR/.env"
DOMAIN="$(env_get SITE_DOMAIN)"
DOMAIN="${DOMAIN:-picklemypaddle.com}"
compose config -q
ok "compose file is valid"

info "Starting the gateway"
compose up -d --pull never --no-deps "${recreate[@]}" --wait --wait-timeout 60 gateway >/dev/null ||
  fail "the gateway did not come back healthy; see: sudo docker compose -p pmp-production logs gateway"
ok "gateway is running"

# A change to .env (HSTS, say) also has to reach the running site. This is a no-op when
# nothing changed, and it never pulls or switches the release: that is update.sh's job.
if [[ -n "$(env_get SITE_VERSION)" && -n "$(compose ps -q site 2>/dev/null)" ]]; then
  compose up -d --pull never --no-deps --wait --wait-timeout 60 site >/dev/null ||
    fail "the site did not come back healthy; see: sudo docker compose -p pmp-production logs site"
  ok "site is running $(env_get SITE_VERSION)"
fi

# Caddy only answers on a name once it holds a certificate for it, so a verified HTTPS
# answer proves DNS, the firewall and the certificate authority all worked.
wait_https() { # wait_https <host>
  local host="$1" deadline=$((SECONDS + CERT_WAIT))
  while ((SECONDS < deadline)); do
    if curl -fsS --max-time 8 "${CURL_OPTS[@]}" --resolve "$host:443:127.0.0.1" "https://$host/gateway-healthz" >/dev/null 2>&1; then
      return 0
    fi
    sleep 3
  done
  return 1
}
info "Waiting for HTTPS certificates (first start can take a minute)"
for host in "www.$DOMAIN" "$DOMAIN"; do
  if wait_https "$host"; then
    ok "https://$host has a valid certificate"
  else
    compose logs --tail 25 gateway >&2 || true
    fail "no valid certificate for $host after ${CERT_WAIT}s. Check: the A record points at this server ('DNS only' in Cloudflare), ports 80/443 are open (ufw and any OVH firewall), then re-run. Log above."
  fi
done

redirect="$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' --max-time 8 \
  --resolve "www.$DOMAIN:80:127.0.0.1" "http://www.$DOMAIN/some/page?x=1" || true)"
[[ "$redirect" == "308 https://www.$DOMAIN/some/page?x=1" ]] ||
  fail "http://www.$DOMAIN should redirect to https (got: ${redirect:-no answer})"
ok "http:// redirects to https://"
redirect="$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' --max-time 8 "${CURL_OPTS[@]}" \
  --resolve "$DOMAIN:443:127.0.0.1" "https://$DOMAIN/some/page?x=1" || true)"
[[ "$redirect" == "301 https://www.$DOMAIN/some/page?x=1" ]] ||
  fail "https://$DOMAIN should redirect to https://www.$DOMAIN (got: ${redirect:-no answer})"
ok "https://$DOMAIN redirects to https://www.$DOMAIN"

version="$(env_get SITE_VERSION)"
if [[ -n "$version" ]]; then
  info "Done. The gateway is up; the site stays on $version (check it: sudo $DEST_DIR/update.sh status)."
else
  info "Done. The gateway is up with HTTPS, and no site release is deployed yet, so visitors see the"
  echo "'temporarily unavailable' page. When a release is ready (runbooks/production-ovh-vps.md):"
  echo "  sudo $DEST_DIR/update.sh deploy vX.Y.Z"
fi
