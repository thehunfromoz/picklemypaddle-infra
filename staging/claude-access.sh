#!/usr/bin/env bash
# Claude Code's access to home-server (SCRUM-92). Called by install.sh:
#
#   sudo ./staging/install.sh --claude-access      on: asks for the Mac's public key (and the
#                                                  address it connects from), then sets it all up
#   sudo ./staging/install.sh --claude-access-off  off: removes the user, key, sudo rule and commands
#   (plain install.sh runs `refresh`: keeps the two commands and the sudo rule current, if on)
#
# Direct use (tests, scripts): claude-access.sh on <public-key-file> <from-pattern> | off | refresh
#
# What "on" means: a user `pmp-claude` with no password and no docker group, whose only SSH key
# is forced to /usr/local/bin/pmp-staging-ssh, from one address; and one sudo rule letting it run
# /usr/local/sbin/pmp-staging (as root, no password) and nothing else. Every call is logged.
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
USER_NAME="pmp-claude"
BIN="/usr/local/sbin/pmp-staging"
SHIM="/usr/local/bin/pmp-staging-ssh"
SUDOERS="/etc/sudoers.d/pmp-claude"

ok() { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
fail() { printf '  \033[31m✗\033[0m %s\n' "$*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || fail "run with sudo"

install_commands() {
  install -o root -g root -m 0755 "$SRC_DIR/pmp-staging" "$BIN"
  install -o root -g root -m 0755 "$SRC_DIR/pmp-staging-ssh" "$SHIM"
  local tmp; tmp="$(mktemp)"
  cat >"$tmp" <<SUDO
# SCRUM-92: Claude Code (user $USER_NAME) may run pmp-staging as root, and nothing else.
# Installed by picklemypaddle-infra staging/claude-access.sh; remove with install.sh --claude-access-off.
Defaults:$USER_NAME !requiretty, env_reset, log_allowed, log_denied
$USER_NAME ALL=(root) NOPASSWD: $BIN
SUDO
  visudo -cqf "$tmp" || { rm -f "$tmp"; fail "the sudo rule didn't validate; nothing changed"; }
  install -o root -g root -m 0440 "$tmp" "$SUDOERS"
  rm -f "$tmp"
}

case "${1:-}" in
  on)
    key_file="${2:-}"; from="${3:-}"
    if [[ -z "$key_file" ]]; then
      echo "Claude Code's SSH key (on the Mac: cat ~/.ssh/pmp-claude.pub)"
      read -rp "  Paste the public key: " key
      default_from="${SSH_CLIENT%% *}"
      read -rp "  Address it connects from [${default_from:-required}]: " from
      from="${from:-$default_from}"
    else
      key="$(<"$key_file")"
    fi
    [[ "$key" =~ ^ssh-ed25519\ [A-Za-z0-9+/=]{60,}(\ [A-Za-z0-9._@-]{1,64})?$ ]] ||
      fail "that isn't an ed25519 public key (one line, starting ssh-ed25519)"
    [[ "$from" =~ ^[0-9a-fA-F.:/,*]{3,100}$ ]] || fail "give the Mac's address (e.g. its LAN or tailnet IP)"
    if ! id "$USER_NAME" >/dev/null 2>&1; then
      useradd --create-home --shell /bin/bash --comment "Claude Code (SCRUM-92)" "$USER_NAME"
      ok "created user $USER_NAME"
    fi
    passwd -l "$USER_NAME" >/dev/null
    if id -nG "$USER_NAME" | tr ' ' '\n' | grep -qxE 'docker|sudo|adm|lxd'; then
      fail "$USER_NAME is in a privileged group (docker, sudo, adm or lxd); remove it from that group first"
    fi
    home="$(getent passwd "$USER_NAME" | cut -d: -f6)"
    install -d -o "$USER_NAME" -g "$USER_NAME" -m 0700 "$home/.ssh"
    printf 'restrict,command="%s",from="%s" %s\n' "$SHIM" "$from" "$key" >"$home/.ssh/authorized_keys"
    chown "$USER_NAME:$USER_NAME" "$home/.ssh/authorized_keys"; chmod 0600 "$home/.ssh/authorized_keys"
    ok "key installed: forced to pmp-staging, from $from only"
    install_commands
    ok "installed $BIN, $SHIM and the sudo rule ($SUDOERS)"
    if command -v sshd >/dev/null && allow="$(sshd -T 2>/dev/null | sed -n 's/^allowusers //p')" && [[ -n "$allow" ]] &&
      ! grep -qw "$USER_NAME" <<<"$allow"; then
      warn "sshd only allows: $allow. Add $USER_NAME to AllowUsers, or Claude can't log in"
    fi
    ok "on. From the Mac: ssh -i ~/.ssh/pmp-claude $USER_NAME@$(hostname) status"
    ;;
  off)
    pkill -u "$USER_NAME" 2>/dev/null || true
    rm -f "$SUDOERS" "$BIN" "$SHIM"
    if id "$USER_NAME" >/dev/null 2>&1; then userdel -r "$USER_NAME" 2>/dev/null || userdel "$USER_NAME"; fi
    ok "off: user, key, sudo rule and commands removed"
    ;;
  refresh)
    if id "$USER_NAME" >/dev/null 2>&1; then install_commands; ok "Claude access: commands and sudo rule up to date"; fi
    ;;
  *) echo "usage: $0 on <key-file> <from> | off | refresh" >&2; exit 2 ;;
esac
