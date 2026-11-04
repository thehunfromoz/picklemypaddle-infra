#!/usr/bin/env bash
# Tests for Claude Code's access to home-server (SCRUM-92): staging/pmp-staging, its SSH forced
# command staging/pmp-staging-ssh, and staging/claude-access.sh.
#
# Part 1 (any machine, not root): pmp-staging in a sandbox with stand-in docker, systemctl,
# journalctl, curl, git and logger.
#   1. help lists the commands; no command means help
#   2. an unknown command is refused (exit 2) and logged as REFUSED
#   3. install refuses every flag but --check (no --set-*, no --tailscale*), and runs install.sh
#      only from the root-owned checkout of origin/main
#   4. logs: only the listed services, 1 to 500 lines
#   5. retry clears that service's known-bad file, then updates
#   6. cli: only the allow-listed CLIs, plain-word arguments
#   7. sql: one read-only select; writes, a second statement and psql backslash commands are
#      refused; the session is read-only at the database too
#   8. settings shows names only, never a value
#   9. the SSH forced command splits words without a shell: ; $( ) and | don't run anything
#  10. every call is logged with the caller
#
# Part 2 (CI only, needs passwordless sudo): claude-access.sh on/off on the real system.
#  11. on: user with a locked password, in no privileged group; key forced to the command,
#      from one address; sudo rule validates, is 0440 and allows pmp-staging only
#  12. as pmp-claude: pmp-staging help works through sudo; any other sudo command is refused;
#      a refused pmp-staging command is in the journal
#  13. refresh keeps it current; off removes the user, key, sudo rule and both commands
# shellcheck disable=SC2015,SC2016,SC2024 # A && B || die is intended; literal $( ) is the point; sudo output goes to our own files
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass() { printf '  \033[32m✓\033[0m %s\n' "$*"; }
die() {
  printf '  \033[31m✗\033[0m %s\n' "$*" >&2
  [[ -f "$WORK/out" ]] && sed 's/^/    | /' "$WORK/out" >&2
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    detail=""; [[ -f "$WORK/out" ]] && detail="$(tail -n 8 "$WORK/out" | sed 's/\x1b\[[0-9;]*m//g' | awk '{printf "%s%%0A", $0}')"
    echo "::error title=claude-access test::$*%0A$detail"
  fi
  exit 1
}

# ---- sandbox -------------------------------------------------------------------------------
SB="$WORK/root"; BIN="$WORK/bin"; CALLS="$WORK/calls"; LOG="$WORK/log"
mkdir -p "$SB/opt/picklemypaddle/staging" "$SB/var/lib/pmp-staging" "$SB/etc/picklemypaddle" "$BIN"
: >"$CALLS"; : >"$LOG"
for c in docker systemctl journalctl curl; do
  printf '#!/usr/bin/env bash\nprintf "%s %%s\\n" "$*" >>"%s"\n' "$c" "$CALLS" >"$BIN/$c"
done
printf '#!/usr/bin/env bash\n[[ "$1" == "-t" ]] && shift 2; [[ "$1" == "--" ]] && shift; printf "%%s\\n" "$*" >>"%s"\n' "$LOG" >"$BIN/logger"
# git: clone makes a checkout whose install.sh records how it was called.
printf '#!/usr/bin/env bash\necho "install.sh $*" >>"%s"\n' "$CALLS" >"$WORK/install.sh.stub"
cat >"$BIN/git" <<GIT
#!/usr/bin/env bash
printf 'git %s\n' "\$*" >>"$CALLS"
if [[ "\$1" == clone ]]; then
  d="\${@: -1}"; mkdir -p "\$d/.git" "\$d/staging"
  install -m 0755 "$WORK/install.sh.stub" "\$d/staging/install.sh"
fi
case "\$*" in *rev-parse*) echo abc1234 ;; *log\ -1*) echo "abc1234 a commit" ;; esac
exit 0
GIT
chmod +x "$BIN"/*
cat >"$SB/etc/picklemypaddle/integrations.env" <<'ENV'
# comment
STRIPE_SECRET_KEY=rk_test_SHOULD_NEVER_BE_PRINTED
HUBSPOT_PORTAL_ID=
ENV

run() { # run <args...>: pmp-staging in the sandbox; output in $WORK/out, exit code in $rc
  rc=0; PATH="$BIN:$PATH" PMP_TEST_ROOT="$SB" "$ROOT/staging/pmp-staging" "$@" >"$WORK/out" 2>&1 || rc=$?
}
ssh_run() { # ssh_run <SSH_ORIGINAL_COMMAND>
  rc=0; (cd "$WORK" && PATH="$BIN:$PATH" PMP_TEST_ROOT="$SB" PMP_STAGING_BIN="$ROOT/staging/pmp-staging" \
    SSH_ORIGINAL_COMMAND="$1" exec "$ROOT/staging/pmp-staging-ssh") >"$WORK/out" 2>&1 || rc=$?
}
refused() { [[ $rc -eq 2 ]] && grep -q 'refused' "$WORK/out"; }
called() { grep -qF -- "$1" "$CALLS"; }

echo "Part 1: pmp-staging in a sandbox"

run help; [[ $rc -eq 0 ]] && grep -q 'retry <site|integrations|editor>' "$WORK/out" || die "1. help should list the commands"
run; grep -q '^  status' "$WORK/out" || die "1. no command should show help"
pass "1. help lists the commands"

run reboot; refused || die "2. an unknown command should be refused with exit 2"
grep -q 'REFUSED: unknown command' "$LOG" || die "2. the refusal should be logged"
pass "2. unknown commands are refused and logged"

for flag in --set-stripe-key --set-token --set-admin-logins --set-editor-app --tailscale --tailscale-off --claude-access-off "--check --set-token"; do
  : >"$CALLS"
  # shellcheck disable=SC2086 # split on purpose: one case passes two flags
  run install $flag; refused || die "3. install $flag should be refused"
  called install.sh && die "3. install.sh must not run for install $flag"
done
: >"$CALLS"; run install --check
[[ $rc -eq 0 ]] || die "3. install --check should run"
called "git clone -q --depth 1 https://github.com/thehunfromoz/picklemypaddle-infra.git" || die "3. should clone infra"
called "git -C $SB/opt/picklemypaddle/src/picklemypaddle-infra fetch -q --depth 1 origin main" || die "3. should fetch origin main"
called "checkout -q --force --detach FETCH_HEAD" || die "3. should check out exactly what was fetched"
called "install.sh --check" || die "3. should run install.sh --check from the checkout"
: >"$CALLS"; run install; called "install.sh " || die "3. plain install should run install.sh"
pass "3. install: only --check, only origin/main from the root checkout"

run logs; refused || die "4. logs without a service should be refused"
run logs sshd; refused || die "4. logs for another service should be refused"
run logs site 501; refused || die "4. more than 500 lines should be refused"
run logs site 0; refused || die "4. 0 lines should be refused"
run logs site '10;id'; refused || die "4. a non-number line count should be refused"
: >"$CALLS"; run logs integrations 50; called "compose -p pmp-staging" && called "logs --no-color --tail 50 integrations" || die "4. logs integrations 50"
: >"$CALLS"; run logs updater; called "journalctl -u pmp-staging-update.service -n 100" || die "4. logs updater"
pass "4. logs: listed services, 1 to 500 lines"

echo bad >"$SB/var/lib/pmp-staging/site.known-bad"; echo bad >"$SB/var/lib/pmp-staging/integrations.known-bad"
run retry postgres; refused || die "5. retry postgres should be refused"
: >"$CALLS"; run retry site
[[ ! -e "$SB/var/lib/pmp-staging/site.known-bad" ]] || die "5. retry site should remove site.known-bad"
[[ -e "$SB/var/lib/pmp-staging/integrations.known-bad" ]] || die "5. retry site must leave integrations.known-bad alone"
called "systemctl start pmp-staging-update.service" || die "5. retry should start the updater"
pass "5. retry clears only that known-bad file and updates"

run cli psql; refused || die "6. a CLI outside the list should be refused"
run cli ../../bin/sh; refused || die "6. a path should be refused"
run cli backdate-order 'PMP-AB;rm -rf /'; refused || die "6. shell characters in arguments should be refused"
run cli backdate-order '$(id)'; refused || die "6. \$( ) in arguments should be refused"
: >"$CALLS"; run cli backdate-order PMP-7K3QX 15d
called "exec -T integrations node dist/cli/backdate-order.js PMP-7K3QX 15d" || die "6. cli backdate-order should run the CLI"
: >"$CALLS"; run cli hubspot-setup --dry-run; called "dist/cli/hubspot-setup.js --dry-run" || die "6. cli with a flag"
pass "6. cli: allow-listed CLIs, plain arguments"

for q in "delete from orders" "select 1; delete from orders" "SELECT 1; SET default_transaction_read_only=off" \
  "update orders set status='x'" "\\! id" "select pg_read_file('/etc/shadow')" "with x as (delete from orders returning *) select * from x" \
  "copy orders to program 'id'"; do
  run sql "$q"; refused || die "7. should refuse: $q"
done
run sql "select 1" "select 2"; refused || die "7. two arguments should be refused"
: >"$CALLS"; run sql "select status, count(*) from orders group by 1;"
[[ $rc -eq 0 ]] || die "7. a select should run"
called "default_transaction_read_only=on" || die "7. the database session must be read-only"
called "psql -U pmp -d pmp -v ON_ERROR_STOP=1 -P pager=off -c select status, count(*) from orders group by 1;" || die "7. should pass the query to psql as one argument"
: >"$CALLS"; run sql "select updated_at, deleted_at from orders"; [[ $rc -eq 0 ]] || die "7. column names containing a blocked word are fine"
pass "7. sql: read-only selects only"

run settings
grep -qx 'STRIPE_SECRET_KEY: set' "$WORK/out" && grep -qx 'HUBSPOT_PORTAL_ID: empty' "$WORK/out" || die "8. settings should list names and set/empty"
grep -q 'SHOULD_NEVER' "$WORK/out" && die "8. settings printed a secret value"
grep -q 'SHOULD_NEVER' "$LOG" && die "8. a secret value reached the log"
pass "8. settings: names only, never values"

for c in 'status; touch PWNED' 'status && touch PWNED' 'status | touch PWNED' '$(touch PWNED)' '`touch PWNED`' "logs site 10'"; do
  ssh_run "$c"
  [[ -e "$WORK/PWNED" ]] && die "9. the forced command ran a shell for: $c"
  [[ $rc -ne 0 ]] || die "9. should be refused: $c"
done
: >"$CALLS"; ssh_run 'pmp-staging sql "select count(*) from orders"'
[[ $rc -eq 0 ]] && called "-c select count(*) from orders" || die "9. a quoted argument should arrive as one word"
ssh_run ''; grep -q '^  status' "$WORK/out" || die "9. an empty SSH command should show help"
pass "9. the SSH forced command splits words without a shell"

: >"$LOG"; SUDO_USER=pmp-claude run status
grep -q '^user=pmp-claude run: status' "$LOG" || die "10. each call should be logged with its caller"
pass "10. every call is logged with the caller"

# ---- part 2 ----------------------------------------------------------------------------------
if [[ -z "${GITHUB_ACTIONS:-}" ]] || ! sudo -n true 2>/dev/null; then
  echo "Part 2 skipped (runs in CI, where sudo needs no password)"
  exit 0
fi
echo "Part 2: claude-access.sh on the CI runner (real user, sudo and journal)"
U=pmp-claude
id "$U" >/dev/null 2>&1 && die "11. the runner already has a $U user"
ssh-keygen -q -t ed25519 -N '' -C "ci@test" -f "$WORK/key"
sudo "$ROOT/staging/claude-access.sh" on "$WORK/key.pub" 192.0.2.10 >"$WORK/out" 2>&1 || die "11. on failed"
home="$(getent passwd "$U" | cut -d: -f6)"
line="$(sudo cat "$home/.ssh/authorized_keys")"
[[ "$line" == "restrict,command=\"/usr/local/bin/pmp-staging-ssh\",from=\"192.0.2.10\" ssh-ed25519 "* ]] || die "11. key line is wrong: $line"
[[ "$(sudo stat -c '%a %U' "$home/.ssh/authorized_keys")" == "600 $U" ]] || die "11. authorized_keys must be 600, owned by $U"
sudo passwd -S "$U" | awk '{print $2}' | grep -qx L || die "11. the password must be locked"
id -nG "$U" | tr ' ' '\n' | grep -qxE 'docker|sudo|adm|lxd' && die "11. $U must not be in a privileged group"
[[ "$(sudo stat -c '%a %U' /etc/sudoers.d/pmp-claude)" == "440 root" ]] || die "11. the sudo rule must be 0440 root"
sudo visudo -cqf /etc/sudoers.d/pmp-claude || die "11. the sudo rule must validate"
for f in /usr/local/sbin/pmp-staging /usr/local/bin/pmp-staging-ssh; do
  [[ "$(stat -c '%a %U' "$f")" == "755 root" ]] || die "11. $f must be 0755 root"
done
pass "11. on: locked user, forced key from one address, valid sudo rule for pmp-staging only"

sudo -u "$U" sudo -n /usr/local/sbin/pmp-staging help >"$WORK/out" 2>&1 || die "12. $U should run pmp-staging help through sudo"
if sudo -u "$U" sudo -n /usr/bin/id >"$WORK/out" 2>&1; then die "12. $U must not run anything else through sudo"; fi
if sudo -u "$U" sudo -n bash -c id >"$WORK/out" 2>&1; then die "12. $U must not get a root shell"; fi
rc=0; sudo -u "$U" env SSH_ORIGINAL_COMMAND='install --set-stripe-key' /usr/local/bin/pmp-staging-ssh >"$WORK/out" 2>&1 || rc=$?
[[ $rc -eq 2 ]] || die "12. a refused command through the forced command should exit 2 (got $rc)"
sleep 1
sudo journalctl -t pmp-staging --since "-2min" --no-pager | grep -q 'user=pmp-claude REFUSED: install takes only --check' ||
  die "12. the refusal should be in the journal"
pass "12. sudo allows pmp-staging only; refusals reach the journal"

echo "# changed" | sudo tee -a /usr/local/sbin/pmp-staging >/dev/null
sudo "$ROOT/staging/claude-access.sh" refresh >"$WORK/out" 2>&1 || die "13. refresh failed"
cmp -s "$ROOT/staging/pmp-staging" /usr/local/sbin/pmp-staging || die "13. refresh should put the current pmp-staging back"
sudo "$ROOT/staging/claude-access.sh" off >"$WORK/out" 2>&1 || die "13. off failed"
id "$U" >/dev/null 2>&1 && die "13. off should remove the user"
for f in /etc/sudoers.d/pmp-claude /usr/local/sbin/pmp-staging /usr/local/bin/pmp-staging-ssh "$home"; do
  sudo test -e "$f" && die "13. off should remove $f"
done
pass "13. refresh keeps it current; off removes everything"
