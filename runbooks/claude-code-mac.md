# Claude Code on the Mac: setup, plugins and the kill switch

Jira: SCRUM-92 (4 Nov 2026). From now on Claude builds PickleMyPaddle with **Claude Code on the Mac
Studio**, not only in cloud sessions. On the Mac it can run Docker, reach home-server (through
`pmp-staging` only, [staging runbook](staging-home-server.md#claude-codes-access-scrum-92)), merge
PRs in a batch you approved, and read CI logs. How we work is in
[docs/working-with-claude.md](../docs/working-with-claude.md).

**What Claude can reach on the Mac:** only the project folder `~/Projects/picklemypaddle` and its
own settings in `~/.claude`. Not the rest of your home folder, and **not** the mounted home-server
home directory (it carries your user's access to everything there), so the project folder must
not be inside that mount.

## One-time setup (Attila)

### 1. A GitHub identity for Claude

**Recommended: a machine account**, e.g. `thehunfromoz-claude` (GitHub allows one free machine
account per person). It is a collaborator with **Write** on the four repos only:

1. Sign out of GitHub (or use a private window), sign up with a new address (an Email Routing
   alias such as `claude@picklemypaddle.com` forwarding to the business Gmail works), turn on 2FA,
   and keep its login and recovery codes the same way as the others (Apple Passwords, iCloud Notes).
2. As `thehunfromoz`, on each repo: Settings → Collaborators → Add people → the machine account →
   **Write**. Accept the four invitations as the machine account.
3. Import the tag ruleset on each repo (step 6). Because the machine account isn't an admin, the
   ruleset stops it creating or moving `v*` tags, so releases stay yours. Its merges show as
   "merged by thehunfromoz-claude", which keeps the record clear.

*Alternative:* a fine-grained token on your own account (the four repos; Contents, Pull requests
read/write; Actions, Checks, Commit statuses read; 90 days). It's quicker, but GitHub treats it as
you, an admin, so the tag ruleset can't stop it; only Claude's own deny rules would.

### 2. The project folder and Claude Code

In Terminal on the Mac:

```bash
mkdir -p ~/Projects/picklemypaddle && cd ~/Projects/picklemypaddle
for r in site integrations agents infra; do git clone https://github.com/thehunfromoz/picklemypaddle-$r; done
ln -s picklemypaddle-infra/workspace/CLAUDE.md CLAUDE.md    # the workspace guide (reads the infra docs)
ln -s picklemypaddle-infra/workspace/.claude .claude        # permissions and project plugins
curl -fsSL https://claude.ai/install.sh | bash      # Claude Code's native installer (macOS 13+)
brew install gh                                      # if `gh --version` says it's missing
gh auth login                                        # GitHub.com → HTTPS → browser; sign in as the machine account
gh auth setup-git                                    # git uses the same login
docker version                                       # Docker Desktop (or OrbStack) running?
```

Commits keep the existing convention (authored as you, with Claude's co-author lines): in each
clone, `git config user.name "Attila Madarasz"` and `git config user.email attila.madarasz@mac.com`.

Start it **from the project folder**: `cd ~/Projects/picklemypaddle && claude`, and sign in with
your Claude account when it asks.

### 3. Jira (Atlassian)

```bash
cd ~/Projects/picklemypaddle
claude mcp add --transport http atlassian https://mcp.atlassian.com/v1/mcp
```

Then, in Claude Code, `/mcp` → atlassian → Authenticate, and sign in to `thehunfromoz.atlassian.net`
in the browser. (If Atlassian's own setup page gives a different address by then, use theirs.)

### 4. The SSH key for home-server

```bash
ssh-keygen -t ed25519 -N '' -C "claude-code@mac-studio" -f ~/.ssh/pmp-claude
cat >>~/.ssh/config <<'CFG'

Host pmp-staging
  HostName home-server
  User pmp-claude
  IdentityFile ~/.ssh/pmp-claude
  IdentitiesOnly yes
CFG
cat ~/.ssh/pmp-claude.pub   # copy this for the next step
```

The key has no passphrase so Claude can use it unattended. That is safe enough because, on
home-server, it can only run `pmp-staging`, and only from the Mac's address.

Then, from an SSH session **started on the Mac**, on home-server:

```bash
cd ~/picklemypaddle-infra && git pull
sudo ./staging/install.sh --claude-access   # paste the key; accept the suggested address (the Mac's)
```

Check from the Mac: `ssh pmp-staging status` shows the timers and containers, and
`ssh pmp-staging install --set-stripe-key` is refused.

If the Mac's LAN address changes (DHCP), the key stops working: give the Mac a DHCP reservation on
the router, or re-run `--claude-access` with the new address. Its tailnet address never changes,
if you'd rather use that (`HostName home-server.tail8bc7ae.ts.net` and the Mac's `100.x` address).

### 5. Plugins (project scope)

In Claude Code, from the project folder:

```text
/plugin install claude-code-setup@claude-plugins-official --scope project
/plugin install pr-review-toolkit@claude-plugins-official --scope project
/plugin install security-guidance@claude-plugins-official --scope project
/plugin install claude-md-management@claude-plugins-official --scope project
```

Record the version of each (`/plugin` → Installed) in the table below. Plugins run with your
permissions in every session, so add others only after reading their hooks.

| Plugin | Why | Version | Since |
| --- | --- | --- | --- |
| claude-code-setup | recommends hooks, skills and subagents per repo (read-only) | [To confirm: version] | SCRUM-92 |
| pr-review-toolkit | the independent pre-merge reviewer (six focused agents) | [To confirm: version] | SCRUM-92 |
| security-guidance | warns about injection, XSS and other risky patterns while editing | [To confirm: version] | SCRUM-92 |
| claude-md-management | keeps `CLAUDE.md` in step with the code; captures session learnings | [To confirm: version] | SCRUM-92 |

Planned after the first batch's UAT: Task Observer (log-only mode, after reading it), and maybe
Context7. On hold: methodology plugins (Agent Skills, Superpowers). Not wanted: claude-mem, Caveman,
Headroom, OmniRoute.

### 6. GitHub settings only you can change

- **Tag ruleset**, on each of the four repos: Settings → Rules → Rulesets → New ruleset → **Import a
  ruleset** → `.github/rulesets/release-tags.json` from this repo. It lets only repository admins
  (you) create, move or delete `v*` tags, so releases (and production) stay yours.
- The branch rulesets stay as they are: PRs and passing checks are required, and no approval, so
  Claude can merge once checks pass.

### 7. Jira: the UAT column

The workflow already has a **QA** status (transition 20). We use it as **"waiting for Attila's
UAT"**: Claude moves a story there when it's on staging with its acceptance script, and only your
OK moves it to Done. If you'd rather it said UAT, rename it under Project settings → Workflows
(nothing else changes).

## Day to day

- Start Claude Code in `~/Projects/picklemypaddle`. The workspace `CLAUDE.md` loads
  `docs/working-with-claude.md` and `docs/qa-gates.md`; each repo's own `CLAUDE.md` adds its commands.
- The workspace `.claude/settings.json` (kept in infra under `workspace/`, so changes go by PR) sets
  what Claude may do without asking (tests, builds, story-branch pushes, `gh` PR work, Docker,
  `ssh pmp-staging …`) and what it may never do (push to `main`, tags and releases, repo settings,
  secrets, `sudo`, reading `.env` files or `~/.ssh`). Anything not listed asks you first.
- Leave it in its normal permission mode; don't start it with `--dangerously-skip-permissions`.

## Kill switch

Any of these stops Claude, on its own or together:

| Stop | How |
| --- | --- |
| home-server access | on home-server: `sudo ./staging/install.sh --claude-access-off` (immediate) |
| GitHub | remove the machine account as collaborator (or revoke its sessions), or revoke the token |
| Jira | Atlassian → Account settings → Connected apps → revoke the MCP app |
| The Mac | close Claude Code; `rm ~/.ssh/pmp-claude*` |
