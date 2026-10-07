#!/usr/bin/env bash
# Install or update the Pickle My Paddle staging stack on home-server (SCRUM-16).
#
#   sudo ./staging/install.sh            install, or apply changes from this checkout
#   sudo ./staging/install.sh --check    only run the pre-flight checks
#
# Safe to re-run: it keeps your existing /opt/picklemypaddle/staging/.env.
# You run this by hand after reviewing a change; nothing runs it automatically.
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST_DIR="/opt/picklemypaddle/staging"
UNIT_DIR="/etc/systemd/system"
CHECK_ONLY=false
[[ "${1:-}" == "--check" ]] && CHECK_ONLY=true

ok() { printf '  \033[32m✓\033[0m %s\n' "$*"; }
fail() { printf '  \033[31m✗\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\n%s\n' "$*"; }

[[ $EUID -eq 0 ]] || fail "run with sudo"

info "Pre-flight checks"
command -v docker >/dev/null || fail "Docker is not installed"
docker info >/dev/null 2>&1 || fail "Docker daemon is not running"
docker compose version >/dev/null 2>&1 || fail "Docker Compose v2 plugin missing (apt install docker-compose-plugin)"
ok "Docker $(docker version -f '{{.Server.Version}}'), $(docker compose version --short | sed 's/^/Compose /')"
command -v python3 >/dev/null || fail "python3 missing (apt install python3)"
command -v flock >/dev/null || fail "flock missing (apt install util-linux)"
ok "python3 and flock present"

# Port: read from the installed .env if present, else the example.
ENV_FILE="$DEST_DIR/.env"
[[ -f "$ENV_FILE" ]] || ENV_FILE="$SRC_DIR/.env.example"
PORT="$(sed -n 's/^STAGING_PORT=//p' "$ENV_FILE" | tail -n1)"
PORT="${PORT:-8088}"
ours="$(docker ps --filter label=com.docker.compose.project=pmp-staging \
  --filter label=com.docker.compose.service=gateway -q)"
if ss -ltnH "sport = :$PORT" | grep -q .; then
  if [[ -n "$ours" ]]; then
    ok "port $PORT is in use by the staging gateway itself (re-install)"
  else
    ss -ltnpH "sport = :$PORT" >&2 || true
    fail "port $PORT is already used by something else; set STAGING_PORT in $ENV_FILE"
  fi
else
  ok "port $PORT is free"
fi

if docker pull -q ghcr.io/thehunfromoz/picklemypaddle-site:staging >/dev/null 2>&1; then
  ok "can pull the site image from GHCR"
else
  fail "cannot pull ghcr.io/thehunfromoz/picklemypaddle-site:staging (no internet, or the package isn't public yet; see the runbook)"
fi

$CHECK_ONLY && { info "Checks passed. Nothing installed (--check)."; exit 0; }

info "Installing to $DEST_DIR"
install -d -m 0755 "$DEST_DIR" "$DEST_DIR/gateway" "$DEST_DIR/hooks"
install -m 0644 "$SRC_DIR/compose.staging.yml" "$DEST_DIR/compose.staging.yml"
install -m 0644 "$SRC_DIR/gateway/Caddyfile" "$DEST_DIR/gateway/Caddyfile"
install -m 0755 "$SRC_DIR/update.sh" "$DEST_DIR/update.sh"
if [[ -f "$DEST_DIR/.env" ]]; then
  ok "kept existing .env"
else
  install -m 0644 "$SRC_DIR/.env.example" "$DEST_DIR/.env"
  ok "created .env from .env.example"
fi
docker compose --project-directory "$DEST_DIR" -f "$DEST_DIR/compose.staging.yml" config -q
ok "compose file is valid"

info "Installing the updater (systemd timer, every 2 minutes)"
install -m 0644 "$SRC_DIR/systemd/pmp-staging-update.service" "$UNIT_DIR/"
install -m 0644 "$SRC_DIR/systemd/pmp-staging-update.timer" "$UNIT_DIR/"
systemctl daemon-reload
systemctl enable --now pmp-staging-update.timer >/dev/null
ok "timer enabled"

info "First update (pulls images, starts the stack, waits for health checks)"
if systemctl start pmp-staging-update.service; then
  ok "staging is up"
else
  journalctl -u pmp-staging-update.service -n 30 --no-pager >&2
  fail "first update failed; see the log above"
fi

# Refresh the gateway image and pick up any gateway config change.
docker compose --project-directory "$DEST_DIR" -f "$DEST_DIR/compose.staging.yml" pull -q gateway || true
docker compose --project-directory "$DEST_DIR" -f "$DEST_DIR/compose.staging.yml" \
  up -d --pull never --force-recreate --no-deps gateway >/dev/null 2>&1 || true
sleep 2

if curl -fsS "http://127.0.0.1:$PORT/healthz" >/dev/null; then
  ok "http://127.0.0.1:$PORT/healthz answers"
else
  fail "the site didn't answer on port $PORT"
fi

info "Done. Open http://home-server:$PORT from your Mac (runbook: runbooks/staging-home-server.md)."
