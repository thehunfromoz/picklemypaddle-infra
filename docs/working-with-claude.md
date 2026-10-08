# Working with Claude on Pickle My Paddle

Read this first in every new Claude session. It's the hand-over between sessions: how we
work, what's decided, and what the build session can't do. Detail lives in Jira, the repo
READMEs and `runbooks/`. Keep this file short and current; update it in the same PR as any
change to how we work.

## The project

Pickle My Paddle re-grits pickleball paddles in Sydney: **A$60 per paddle, both faces**,
plus return postage. Individuals post paddles in; clubs hand over batches for pickup and earn
10%. Owner: Attila Madarasz.

| Repo (github.com/thehunfromoz) | What |
| --- | --- |
| `picklemypaddle-site` | Astro 7 + Tailwind v4 website (static, served by Caddy) |
| `picklemypaddle-integrations` | TypeScript/Node 22 service (Hono, zod): orders, HubSpot, Stripe |
| `picklemypaddle-agents` | TypeScript/Node 22: helper agents (all parked) |
| `picklemypaddle-infra` | Staging stack, updater, shared CI workflows, runbooks, this guide |

Jira: https://thehunfromoz.atlassian.net, project **SCRUM**. Epics: SCRUM-6 platform (done
apart from parked OVH stories 19/20 and Tailscale SCRUM-38), SCRUM-7 website (stories 29–37),
SCRUM-8 orders, SCRUM-9 payments, SCRUM-10 clubs, SCRUM-11 launch, SCRUM-12 agents,
SCRUM-21 security/privacy.

## How we work

- **Quiz before building:** every story gets acceptance criteria, tests and a Definition of
  Done (CI green, deployed to staging with a green `staging/home-server` tick, Attila's
  approval where the story says so) before work starts.
- **Jira statuses (Claude moves tickets):** BACKLOG → To Do (approved) → Open (this sprint)
  → In Progress → In Review (PR up) → QA (tests/checks running) → MERGE (green, waiting for
  Attila) → Done (merged and acceptance checks verified). Assessment = parked for later.
  Blocked = needs Attila; always say exactly what is needed. There is no Re-opened
  transition: move a failed ticket back to In Progress with a comment.
  Transition IDs: To Do 11, Open 17, In Progress 18, In Review 19, QA 20, Done 21,
  MERGE 24, Blocked 3, Assessment 23.
- **Before marking anything Blocked or Done, verify it** (CI results, commit statuses,
  `version.txt`). Don't assume.
- **Only Attila merges to `main`.** Rulesets enforce PRs and passing checks on all repos.
- **Branches:** `scrum-<n>-<short-name>`. Squash noisy work into clean commits before review.
- **Commits** are authored `Attila Madarasz <attila.madarasz@mac.com>` and end with the
  session's `Co-Authored-By` / `Claude-Session` lines. PR descriptions end with the
  "Generated with Claude Code" line and the session link.
- **Copy:** Claude drafts, Attila approves on staging. Unknown facts are written
  `[To confirm: …]`; `pnpm check:placeholders` blocks releases while any remain, and
  visitors never see placeholders (sections stay hidden instead).
- **Keep token use modest:** check CI once rather than polling in long loops; request only
  the Jira fields needed.

## What the build session can't do (GitHub proxy limits)

These need Attila, so give him exact click-paths or commands:

- create or delete **tags/releases** (releases: GitHub → Releases → Draft new release);
- change **repo settings / rulesets** (send importable ruleset JSON instead);
- **delete branches**;
- read some Actions/package APIs (logs, artifacts): make CI print failures as `::error`
  annotations, then read them from the check-run annotations API;
- reach the npm registry, so dependencies can't be installed in the session. To create or
  refresh `pnpm-lock.yaml`, push a temporary workflow on the branch that runs
  `pnpm install --lockfile-only`, commits the lockfile back and deletes itself; then
  squash the branch.
- create PRs with `gh pr create` (no GraphQL): use
  `gh api repos/<owner>/<repo>/pulls -f title=… -f head=… -f base=main -F body=@file`.

Nothing on Attila's LAN can be reached from the session. home-server results come back
through GitHub commit statuses, or Attila pastes command output.

## CI and releases

- All repos call the shared workflows here (`.github/workflows/`): `node-checks.yml`,
  `secret-scan.yml`, `image.yml`, `release.yml`. Callers pin `@main`. Changes here are
  tested from a branch ref first.
- Required checks: site/integrations `checks / Checks`, `secrets / Secret scan`,
  `image / Image`; agents `checks / Checks`, `secrets / Secret scan`; infra its own job
  names plus `Lint GitHub workflows` and `secrets / Secret scan`. **Renaming a job
  changes its check name**, so new ruleset files are needed, merged in the right order.
- Merge to `main` publishes `ghcr.io/thehunfromoz/<repo>:staging` and `:<sha>` (site also
  `picklemypaddle-site-smoke:<sha>`). A `vX.Y.Z` release re-tags without rebuilding.

## Staging (home-server, 192.168.1.24, Ubuntu)

- http://home-server:8088: the gateway routes `/api/*` to integrations, everything else to
  the site. `/version.txt` shows the live site commit.
- A pull-based updater (systemd timer, 2 min) deploys, health-checks, runs the smoke tests
  and rolls back on failure. It posts the result as a `staging/home-server` commit status.
  Full detail is in `runbooks/staging-home-server.md`.
- Changes to `staging/` take effect only after `git pull && sudo ./staging/install.sh` on
  home-server (`--check` warns when the installed files are stale).
- Secrets live only on home-server (root, 600): `/etc/picklemypaddle/github-status.token`
  and `/etc/picklemypaddle/integrations.env` (test-mode keys only).
- **Tailscale:** `https://home-server.tail8bc7ae.ts.net` (port 443) already serves another
  app (`localhost:3000`). Don't touch it. Staging is planned on `:8443` (SCRUM-38).

## Decisions worth knowing

- Payment after photo assessment; private status links, no customer accounts.
- Clubs keep their members' details; they pay by PayID, Stripe invoice or cash on delivery.
- Return postage is charged separately; not GST-registered (ABN before launch).
- Turnaround: back in the post within 10 business days of arrival. Order reply within
  1 business day.
- Re-gritted paddles are not legal for sanctioned tournaments; say so near pricing.
- Brand C3b: court blue `#4565A6`, court green `#78A472` (green text `#3F6B3E`), ink
  `#1E2E52`, background `#FBFAF6`; Sora + Work Sans (self-hosted); strict CSP, no inline
  scripts or third-party origins.
- Website choices: self-hosted Umami analytics; gallery from Attila's own re-grits (shown
  from 3 pairs); testimonials with permission (shown from 3); Keystatic on staging behind
  Tailscale, with posts in `src/content/blog/<lang>/`.
- Agents draft and Attila approves; nothing is sent or paid automatically.
