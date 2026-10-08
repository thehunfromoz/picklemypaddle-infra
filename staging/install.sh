#!/usr/bin/env bash
# Install or update the Pickle My Paddle staging stack on home-server (SCRUM-16).
#
#   sudo ./staging/install.sh              install, or apply changes from this checkout
#   sudo ./staging/install.sh --check      only run the pre-flight checks
#   sudo ./staging/install.sh --set-token  store (or replace) the GitHub token used
#                                          to post "staging" commit statuses (SCRUM-17)
#
# Safe to re-run: it keeps your existing /opt/picklemypaddle/staging/.env.
# You run this by hand after reviewing a change; nothing runs it automatically.
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST_DIR="/opt/picklemypaddle/staging"
UNIT_DIR="/etc/systemd/system"
TOKEN_FILE="/etc/picklemypaddle/github-status.token"
STATUS_REPO="thehunfromoz/picklemypaddle-site"
SECRETS_FILE="/etc/picklemypaddle/integrations.env"
IMAGES=(ghcr.io/thehunfromoz/picklemypaddle-site:staging ghcr.io/thehunfromoz/picklemypaddle-integrations:staging)
CHECK_ONLY=false
SET_TOKEN=false
case "${1:-}" in
  --check) CHECK_ONLY=true ;;
  --set-token) SET_TOKEN=true ;;
  "") ;;
  *) echo "usage: sudo $0 [--check|--set-token]" >&2; exit 2 ;;
esac

ok() { printf '  \033[32m✓\033[0m %s\n' "$*"; }
fail() { printf '  \033[31m✗\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\n%s\n' "$*"; }

[[ $EUID -eq 0 ]] || fail "run with sudo"

# Ask GitHub whether a token can see the repo it will post statuses to.
token_works() { # token_works <file>
  printf 'header = "Authorization: Bearer %s"\n' "$(tr -d '[:space:]' <"$1")" |
    curl -fsS --config - --max-time 15 -o /dev/null \
      -H "Accept: application/vnd.github+json" "https://api.github.com/repos/$STATUS_REPO"
}

if $SET_TOKEN; then
  info "GitHub status token (fine-grained, only '$STATUS_REPO', only 'Commit statuses: Read and write')"
  read -rsp "  Paste the token (input hidden): " token
  echo
  [[ "$token" == github_pat_* ]] || fail "that doesn't look like a fine-grained token (should start with github_pat_)"
  install -d -m 0700 "$(dirname "$TOKEN_FILE")"
  tmp="$(mktemp "$(dirname "$TOKEN_FILE")/.token.XXXXXX")"
  printf '%s\n' "$token" >"$tmp"
  unset token
  chmod 0600 "$tmp"
  token_works "$tmp" || { rm -f "$tmp"; fail "GitHub rejected the token, or it can't see $STATUS_REPO"; }
  mv "$tmp" "$TOKEN_FILE"
  ok "token saved to $TOKEN_FILE (root-only) and accepted by GitHub"
  exit 0
fi

info "Pre-flight checks"
command -v docker >/dev/null || fail "Docker is not installed"
docker info >/dev/null 2>&1 || fail "Docker daemon is not running"
docker compose version >/dev/null 2>&1 || fail "Docker Compose v2 plugin missing (apt install docker-compose-plugin)"
ok "Docker $(docker version -f '{{.Server.Version}}'), $(docker compose version --short | sed 's/^/Compose /')"
command -v python3 >/dev/null || fail "python3 missing (apt install python3)"
command -v flock >/dev/null || fail "flock missing (apt install util-linux)"
ok "python3 and flock present"
command -v curl >/dev/null || fail "curl missing (apt install curl)"
command -v timeout >/dev/null || fail "timeout missing (apt install coreutils)"

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

for img in "${IMAGES[@]}"; do
  if docker pull -q "$img" >/dev/null 2>&1; then
    ok "can pull ${img#ghcr.io/thehunfromoz/}"
  else
    fail "cannot pull $img (no internet, or the package isn't public yet; see the runbook)"
  fi
done

if [[ -f "$SECRETS_FILE" ]]; then
  perms="$(stat -c '%a %U' "$SECRETS_FILE")"
  if [[ "$perms" == "600 root" ]]; then ok "integrations secrets file is root-only"; else
    fail "$SECRETS_FILE must be owned by root with mode 600 (is: $perms); fix: sudo chmod 600 $SECRETS_FILE && sudo chown root:root $SECRETS_FILE"; fi
else
  printf '  \033[33m!\033[0m %s will be created (empty; add TEST-mode keys later, see runbook)\n' "$SECRETS_FILE"
fi

if [[ -r "$TOKEN_FILE" ]]; then
  if token_works "$TOKEN_FILE"; then ok "GitHub status token works"; else
    printf '  \033[33m!\033[0m GitHub status token is rejected (expired?). Replace it: sudo %s --set-token\n' "$0"; fi
else
  printf '  \033[33m!\033[0m no GitHub status token yet: staging works, but results won'"'"'t show on GitHub.\n    Add one with: sudo %s --set-token (see runbook)\n' "$0"
fi

# Is what's installed in /opt the same as this checkout? (The timer runs /opt.)
stale=""
for f in compose.staging.yml gateway/Caddyfile update.sh; do
  cmp -s "$SRC_DIR/$f" "$DEST_DIR/$f" 2>/dev/null || stale="$stale $f"
done
for f in pmp-staging-update.service pmp-staging-update.timer; do
  cmp -s "$SRC_DIR/systemd/$f" "$UNIT_DIR/$f" 2>/dev/null || stale="$stale $f"
done
if [[ -n "$stale" ]]; then
  printf '  \033[33m!\033[0m installed files differ from this checkout:%s\n    Apply them with: sudo %s\n' "$stale" "$0"
else
  ok "installed files match this checkout"
fi

$CHECK_ONLY && { info "Checks passed. Nothing installed (--check)."; exit 0; }

info "Installing to $DEST_DIR"
install -d -m 0755 "$DEST_DIR" "$DEST_DIR/gateway"
install -d -m 0700 "$(dirname "$SECRETS_FILE")"
if [[ ! -f "$SECRETS_FILE" ]]; then
  ( umask 077; cat >"$SECRETS_FILE" <<'SECRETS'
# Pickle My Paddle integrations service: STAGING secrets. Root-only (chmod 600).
# TEST-MODE values only: the service refuses a live Stripe key on staging.
# Leave a value empty until its integration is built. After editing, apply with:
#   cd ~/picklemypaddle-infra && sudo ./staging/install.sh
# APP_ENV, PORT and PUBLIC_SITE_ORIGIN are set in compose.staging.yml, not here.
STRIPE_SECRET_KEY=
STRIPE_WEBHOOK_SECRET=
HUBSPOT_ACCESS_TOKEN=
HUBSPOT_PORTAL_ID=
SECRETS
  )
  ok "created $SECRETS_FILE (root-only, empty)"
else
  chmod 600 "$SECRETS_FILE"; chown root:root "$SECRETS_FILE"
  ok "kept $SECRETS_FILE (root-only)"
fi
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

# Restart integrations if its settings (secrets file) changed; no-op otherwise.
docker compose --project-directory "$DEST_DIR" -f "$DEST_DIR/compose.staging.yml" \
  up -d --pull never --no-deps integrations >/dev/null 2>&1 || true

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
