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
   alias on picklemypaddle.com forwarding to the business Gmail; the one in use is in Apple Passwords), turn on 2FA,
   and keep its login and recovery codes the same way as the others (Apple Passwords, iCloud Notes).
2. As `thehunfromoz`, on each repo: Settings → Collaborators → Add people → the machine account →
   **Write**. Accept the four invitations as the machine account, in a **private browser window**
   signed in as `thehunfromoz-claude`, at `https://github.com/thehunfromoz/<repo>/invitations`
   (the link in the email opens as `thehunfromoz`, the wrong account).
3. Import the tag ruleset on each repo (step 6). Because the machine account isn't an admin, the
   ruleset stops it creating or moving `v*` tags, so releases stay yours. Its merges show as
   "merged by thehunfromoz-claude", which keeps the record clear.

*Alternative:* a fine-grained token on your own account (the four repos; Contents, Pull requests
read/write; Actions, Checks, Commit statuses read; 90 days). It's quicker, but GitHub treats it as
you, an admin, so the tag ruleset can't stop it; only Claude's own deny rules would.

### 2. The project folder and Claude Code

In Terminal on the Mac, paste these **without** `# comments` on the command lines (zsh doesn't treat
them as comments when you type interactively, and `gh` received them as arguments):

```bash
mkdir -p ~/Projects/picklemypaddle && cd ~/Projects/picklemypaddle
for r in site integrations agents infra; do git clone https://github.com/thehunfromoz/picklemypaddle-$r; done
ln -s picklemypaddle-infra/workspace/CLAUDE.md CLAUDE.md
mkdir .claude
ln -s ../picklemypaddle-infra/workspace/.claude/settings.json .claude/settings.json
curl -fsSL https://claude.ai/install.sh | bash
brew install gh
gh auth login
gh auth setup-git
```

What they do: the `ln -s` lines link the workspace guide and the project settings (permissions and
model) from the infra repo. `.claude` is a **real folder** holding only that one link, so Claude Code can
write its own files there: `settings.local.json` (what "Yes, don't ask again" saves) and plugin files.
(Until 5 Nov 2026 the whole folder was a link, which made "don't ask again" and project-scope plugin
installs fail. On a Mac set up that way: `cd ~/Projects/picklemypaddle && rm .claude && mkdir .claude &&
ln -s ../picklemypaddle-infra/workspace/.claude/settings.json .claude/settings.json`. `rm .claude` removes
only the link.)
 the installer is Claude Code's native one (macOS 13+); `brew install gh` is needed only if
`gh --version` says it's missing; `gh auth setup-git` makes git use the same login.

- **`gh auth login`:** choose GitHub.com → HTTPS → browser. It shows a one-time code and opens
  github.com/login/device. Approve it in a **private window signed in as `thehunfromoz-claude`**, not
  in your usual browser (that is signed in as you).
- **Docker:** `open -a Docker`, wait until it says it is running, then `docker version` must show a
  **Server** section as well as the Client. Docker Desktop's setting "Start Docker Desktop when you sign
  in to your computer" saves doing this each time.

Commits keep the existing convention (authored as you, with Claude's co-author lines): in each
clone, `git config user.name "Attila Madarasz"` and `git config user.email attila.madarasz@mac.com`.

Start it **from the project folder**: `cd ~/Projects/picklemypaddle && claude`, and sign in with
your Claude account when it asks.

### 3. Jira (Atlassian)

```bash
cd ~/Projects/picklemypaddle
claude mcp add --transport http atlassian https://mcp.atlassian.com/v2/mcp
```

That adds it at local scope (this folder, this Mac). Then, in Claude Code, `/mcp` → atlassian →
Authenticate, and sign in to `thehunfromoz.atlassian.net` in the browser. Atlassian's current address
is the `v2` one above (checked 5 Nov 2026; the old `v1` address is retired).

### 4. The SSH key for home-server

Claude reaches home-server **over the tailnet**, not the LAN: Tailscale must be signed in on the Mac
(the same tailnet as home-server). MagicDNS puts even a plain `ssh home-server` from the Mac on
the tailnet: observed 5 Nov 2026, it arrived on home-server (`SSH_CLIENT`) from the Mac's tailnet
address (a `100.x` one), and that is the address the key is locked to. Get it with `tailscale ip -4` on the Mac (or in the Tailscale
menu); call it *the Mac's tailnet address* below. It doesn't change, so no DHCP reservation is needed.

```bash
ssh-keygen -t ed25519 -N '' -C "claude-code@mac-studio" -f ~/.ssh/pmp-claude
cat >>~/.ssh/config <<'CFG'

Host pmp-staging
  HostName home-server.tail8bc7ae.ts.net
  User pmp-claude
  IdentityFile ~/.ssh/pmp-claude
  IdentitiesOnly yes
CFG
tailscale ip -4
cat ~/.ssh/pmp-claude.pub
```

The key has no passphrase so Claude can use it unattended. That is safe enough because, on
home-server, it can only run `pmp-staging`, and only from the Mac's tailnet address.

Then put the key on home-server. The simplest way is to copy the public key there (for example,
`scp ~/.ssh/pmp-claude.pub home-server:/tmp/pmp-claude.pub` from the Mac), then, in an SSH session on
home-server:

```bash
cd ~/picklemypaddle-infra && git pull
sudo ./staging/install.sh --claude-access /tmp/pmp-claude.pub <the Mac's tailnet address>
```

With no arguments, `sudo ./staging/install.sh --claude-access` asks for the pasted key and the address
instead. The address must be exactly one IPv4 or IPv6 address: `*`, lists and ranges are refused. It suggests an address only if it can read the session's own (often not, under `sudo`), and
it won't continue without one. What it suggests, if you SSH in over the tailnet, is the right answer.

Check from the Mac: `ssh pmp-staging status` shows the timers and containers, and
`ssh pmp-staging install --set-stripe-key` is refused (both checked 5 Nov 2026).

Access works **only while Tailscale is up on the Mac**: with it off or signed out, `ssh pmp-staging`
times out. That is expected, and it is also a switch you control (see the kill switch below).

### 5. Plugins (this folder only)

`/plugin install … --scope project` **fails** here (`SymlinkWriteRefusedError: Refusing to write into
symlinked directory …/.claude`), because the project's `.claude` is a symlink into the infra repo.
What works:

1. The four plugins are already listed under `enabledPlugins` in `workspace/.claude/settings.json`
   (committed, so a change goes by PR); that is what makes them active in this folder.
2. Download them once, from Terminal (not inside Claude Code):

   ```bash
   claude plugin install claude-code-setup@claude-plugins-official --scope user
   claude plugin install pr-review-toolkit@claude-plugins-official --scope user
   claude plugin install security-guidance@claude-plugins-official --scope user
   claude plugin install claude-md-management@claude-plugins-official --scope user
   ```

3. `--scope user` also switches them on everywhere. Open `~/.claude/settings.json` and delete those
   four lines from its `enabledPlugins` (leave the downloaded files), so they are active only in this
   folder. Check: started from `/tmp`, `claude` doesn't list them; started here, it does.
   Validate the file after editing it with `python3 -m json.tool ~/.claude/settings.json` (it prints
   the JSON, or says where it is broken). Don't use `plutil -lint`: that checks plists only.

Record the version of each (`/plugin` → Installed) in the table below. Plugins run with your
permissions in every session, so add others only after reading their hooks.

| Plugin | Why | Version | Since |
| --- | --- | --- | --- |
| claude-code-setup | recommends hooks, skills and subagents per repo (read-only) | 1.0.0 | SCRUM-92 (installed 5 Nov 2026) |
| pr-review-toolkit | the independent pre-merge reviewer (six focused agents) | 1.0.1 | SCRUM-92 (installed 5 Nov 2026) |
| security-guidance | warns about injection, XSS and other risky patterns while editing | 2.0.17 | SCRUM-92 (installed 5 Nov 2026) |
| claude-md-management | keeps `CLAUDE.md` in step with the code; captures session learnings | 1.0.0 | SCRUM-92 (installed 5 Nov 2026) |

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
OK moves it to Done. It stays named **QA**
(decided 5 Nov 2026).

## Day to day

- Start Claude Code in `~/Projects/picklemypaddle`. The workspace `CLAUDE.md` loads
  `docs/working-with-claude.md` and `docs/qa-gates.md`; each repo's own `CLAUDE.md` adds its commands.
- The workspace `.claude/settings.json` (kept in infra under `workspace/`, so changes go by PR) sets
  what Claude may do without asking and what it may never do. Anything not listed asks you first.
  See "Permissions" below.
- **The live permissions are whatever the infra clone has checked out.** `.claude/settings.json` is a link
  into `picklemypaddle-infra/workspace/`, so a branch checked out there is the permission set Claude runs
  under, before anyone has reviewed it. Permission changes are therefore made in a separate worktree
  (`git worktree add`), and take effect only when you merge the PR and the clone is back on an updated `main`.
- "Yes, don't ask again" saves to `.claude/settings.local.json` (this Mac only, not in git). Look at it now
  and then (`cat ~/Projects/picklemypaddle/.claude/settings.local.json`) and move anything lasting into
  `settings.json` by PR.
- **Models:** `settings.json` sets `"model": "opusplan"`: Opus in plan mode, Sonnet when building. See
  [working-with-claude.md](../docs/working-with-claude.md#models).
- **Merging:** auto mode's classifier blocks `gh pr merge`, so you merge by hand until that changes; Claude
  says when a PR is ready.
- Leave it in its normal permission mode; don't start it with `--dangerously-skip-permissions`.

### Permissions: what is allowed without asking

Worked out on 5 Nov 2026 from the day's sessions (about 270 tool calls, 19 transcripts; the transcripts
record what ran, not which prompts you saw, so "would have asked" means "not covered by the list then").

| Group | Allowed without asking | Why |
| --- | --- | --- |
| Read-only shell | `ls`, `cat`, `head`, `tail`, `grep`, `sed -n`, `cut`, `wc`, `sort`, `uniq`, `diff`, `date`, `which`, `ps`, `lsof`, `sleep`, `mkdir` | They only look (`sed -n` only prints). |
| git, read-only | `git status/log/diff/show/fetch/branch/rev-parse` also in the form `git -C <dir> …`; `git grep`, `ls-tree`, `reflog`, `remote -v`, `worktree list`, `stash list`, `config --get` | Looking at other clones and branches. |
| git, local-only writes | `git merge`, `git stash push/pop`, `git worktree add` | Change only the local clone; pushing stays limited to `scrum-*` branches. |
| git push | `git push -q [-u] origin scrum-*` (the `-q` forms) | Same branches as before. |
| gh | `gh api rate_limit` | Read-only. |
| pnpm | `pnpm -C <dir>` and `pnpm --filter <pkg>` with install, run, test, exec, check, lint, build, typecheck | The verbs already allowed, from another folder. |
| Other | `python3 -m json.tool`, `bash ci/container-test.sh`, `npm view`, `curl` to `localhost` | Named in the docs or read-only. |
| Atlassian (both servers) | read tools; add or edit a comment; move a status; create an issue link | [working-with-claude.md](../docs/working-with-claude.md) gives Claude these (Jira statuses, blocked-by links, test reports). |

**Added to the deny list:** `Bash(*/.ssh*)`. Allowing `cat` and `grep` would otherwise let the shell read
`~/.ssh`, which `Read(~/.ssh/**)` doesn't cover.

**Left out on purpose** (still asks, or stays denied):
`python3 -` (and other heredoc-fed interpreters) and `awk`, `find`, `xargs`: they run arbitrary code or
commands; Claude edits files with its Edit tool instead. `rm`, `cp`, `chmod`, `kill`: they destroy or
overwrite. `git reset`, `git clean`, `git stash drop`: they discard work (`git reset --hard` was blocked
by auto mode on 5 Nov 2026; adding it to the deny list is worth considering). A bare `git push` (it pushes
whatever the current branch tracks, which on `main` is `main`). `gh api -X …` and `gh pr merge` stay as
before (the latter is blocked in auto mode anyway). `brew install`, `ssh-keygen`, `gh auth`, `sudo`.
Atlassian: creating or editing issues and any Confluence write (refinement work you should see), plus
`executeWrite` and `executeDestructive`. The other connectors (Supabase, Postman, Figma, Google Drive,
Swagger) aren't used in this project.

Not yet enforced: Claude can edit `workspace/.claude/settings.json` itself (edits inside the project folder
are allowed). The safeguard is process, the worktree rule above and your review of the PR. To make it
enforced, deny `Edit` on that file and make permission PRs yourself.

### Sandbox (evaluated 5 Nov 2026)

Claude Code's macOS sandbox (Seatbelt, `/sandbox`) is off by default and has not been run live yet. From its
documentation and this Mac:

- Seatbelt is available here (`sandbox-exec` exists). Docker's socket sits under `~/.docker/run`.
- `docker`, `gh` (Go CLIs fail TLS inside it), plain `ssh` and git over SSH don't work inside it and must
  be listed in `sandbox.excludedCommands`. Our remotes are HTTPS, so git works if `github.com` is allowed.
  Excluded commands run with full access, so the riskiest commands here (`docker`, `gh`, `ssh
  pmp-staging`) would be unsandboxed anyway. `ssh pmp-staging` is already boxed in by its forced command.
- It needs an allowed-domains list (npm registry, Playwright's download host, GitHub) and
  `allowLocalBinding` for the dev server and Playwright. A script that calls `docker` inside a `make` target
  stays sandboxed, because exclusion matches the command text.
- What it adds: shell commands (python, pnpm, rm, cp, sed -i) are confined to the project folder, and
  sandboxed commands run without prompts, which would replace much of the allow list above.

**Recommendation: for it, as a one-week trial, not yet in `settings.json`.** The confinement of file and
network access is real value next to the permission list, and it would cut prompts. But Chromium under
Playwright, pnpm installs and `git push` over HTTPS are unproven under it on this Mac, and a wrong exclusion
list is silently unsandboxed. Trial: `/sandbox` with `excludedCommands` `docker *`, `gh *`, `ssh pmp-staging *`;
then check `pnpm install`, `pnpm test:e2e` (Chromium), `git push` of a scrum branch, `docker version`,
`ssh pmp-staging status` and `gh pr list`; commit the settings only when all six work.

## Kill switch

Any of these stops Claude, on its own or together:

| Stop | How |
| --- | --- |
| home-server access | on home-server: `sudo ./staging/install.sh --claude-access-off` (immediate) |
| home-server access, from the Mac | quit Tailscale on the Mac (or sign it out): `ssh pmp-staging` stops working at once, and returns when Tailscale does |
| GitHub | remove the machine account as collaborator (or revoke its sessions), or revoke the token |
| Jira | Atlassian → Account settings → Connected apps → revoke the MCP app |
| The Mac | close Claude Code; `rm ~/.ssh/pmp-claude*` |
