# Working with Claude on PickleMyPaddle

Read this first in every new Claude session. It's the hand-over between sessions: how we
work, what's decided, and what the build session can't do. Detail lives in Jira, the repo
READMEs and `runbooks/`; where every account, server and secret lives is in
[as-built.md](as-built.md). Keep this file short and current; update it in the same PR as any
change to how we work.

## The project

PickleMyPaddle re-grits pickleball paddles in Sydney: **A$60 per paddle, both faces**,
plus return postage. Individuals post paddles in; clubs hand over batches for pickup and earn
10%. Owner: Attila Madarasz.

| Repo (github.com/thehunfromoz) | What |
| --- | --- |
| `picklemypaddle-site` | Astro 7 + Tailwind v4 website (static, served by Caddy) |
| `picklemypaddle-integrations` | TypeScript/Node 22 service (Hono, zod): orders, HubSpot, Stripe |
| `picklemypaddle-agents` | TypeScript/Node 22: helper agents (all parked) |
| `picklemypaddle-infra` | Staging and production stacks, updaters, shared CI workflows, runbooks, this guide |

Jira: https://thehunfromoz.atlassian.net, project **SCRUM**. Statuses below as of 29 Oct 2026; Jira is
the record. Epics:

- **SCRUM-6 platform:** done apart from 20 (production releases), BLOCKED until the first
  production release.
- **SCRUM-7 website:** launch gates 31 (privacy and terms: ABN, postage, lost/damaged; BLOCKED) and
  79 (About photo, measured paddle weight), plus 35 (analytics, needed for launch). 32 (gallery) and
  33 (testimonials, built) are BLOCKED on real re-grits and real customers; 41 is parked.
- **SCRUM-8 orders** (stories 64–75, refined 26 Oct 2026): part 1, 64–68 and 70 with website story
  40, built 26 Oct; part 2, 28–29 Oct: emails 69 done; HubSpot 74 built, waiting on its admin
  staging check; part 3, 29 Oct: admin 71/72 built (integrations #14, infra PR #32), waiting on
  merge, Attila's Tailscale Serve steps and his phone walk-through; queue 73 built (integrations
  #15 on #14, site #52); next: 75. Also launch gates 63 (discount codes) and bug 76 (iPhone photos).
- **SCRUM-11 launch:** its "is blocked by" links are the launch checklist.
- SCRUM-9 payments, SCRUM-10 clubs, SCRUM-12 agents, SCRUM-21 security/privacy.

## How we work

- **Quiz before building:** every story gets acceptance criteria, tests and a Definition of
  Done (CI green, deployed to staging with a green `staging/home-server` tick, Attila's
  approval where the story says so) before work starts.
- **Jira statuses (Claude moves tickets).** List the ticket's transitions
  (`getTransitionsForJiraIssue`) before moving it: the ids differ by issue type. **Stories and
  Bugs** (checked 29 Oct 2026): To Do 11, In Progress 18, **BLOCKED 3**, Done 21, Assessment 23
  (parked), CLOSED 2; there is no transition back to BACKLOG. **Tasks** (SCRUM-59 to 61, 22 Oct)
  offer only Begin Work (2) and **Done (3)**, so never reuse ids across types.
  - **In Progress** only while the work is actively going on, including fixing a failed check.
  - **BLOCKED** whenever it is waiting on anything else: Attila (an approval, a manual step, a
    decision, content), another story, the launch, or real customers. Every move to BLOCKED gets
    an "is blocked by" link to what it waits on (the epic, such as SCRUM-11, when no story fits)
    and a comment saying exactly what is needed, from whom, and when. Move it back to In Progress
    when the work resumes.
  - Don't leave a story in MERGE (or another in-between status) once its PR is merged.
  - **Done** only once the acceptance checks are verified and Attila has approved where the
    ticket says so. A loose end that doesn't affect the story's purpose can go to a new linked
    story (as SCRUM-79 did for SCRUM-30) instead of holding it open.
  - Anything that must be finished before go-live "blocks" SCRUM-11.
- **Before marking anything Blocked or Done, verify it** (CI results, commit statuses,
  `version.txt`). Don't assume.
- **Only Attila merges to `main`.** Rulesets enforce PRs and passing checks on all repos.
- **Branches:** `scrum-<n>-<short-name>`. Squash noisy work into clean commits before review.
  The session's clones are **shallow**: don't `commit --amend` or squash with
  `reset --soft` onto a shallow boundary (it once produced a parentless commit and an
  unrecoverable PR). Squash on a fresh branch from `origin/main`, and check
  `git rev-parse HEAD^` before force-pushing. After pushing a new branch, set its upstream
  so the stop hook sees it as pushed: the clone only fetches `main`, so first
  `git config --add remote.origin.fetch '+refs/heads/<b>:refs/remotes/origin/<b>'`, then set
  `branch.<b>.remote` and `branch.<b>.merge`.
- **A PR that has fallen behind `main`** can be brought up to date without a local rebase:
  `gh api -X PUT repos/<owner>/<repo>/pulls/<n>/update-branch -f expected_head_sha=<sha>`
  (it adds a merge commit and re-runs the checks; done on site #38, SCRUM-59).
- **Commits** are authored `Attila Madarasz <attila.madarasz@mac.com>` and end with the
  session's `Co-Authored-By` / `Claude-Session` lines. PR descriptions end with the
  "Generated with Claude Code" line and the session link.
- **Copy:** Claude drafts, Attila approves on staging. Unknown facts are written
  `[To confirm: …]`; `pnpm check:placeholders` blocks releases while any remain, and
  visitors never see placeholders (sections stay hidden instead).
- **Keep token use modest:** check CI once rather than polling in long loops; request only
  the Jira fields needed.
- **A green tick isn't proof.** Check that a test actually ran (annotations, the published
  image, the staging status text). Since 13 Oct this has caught: test steps that never
  failed a job, a smoke image that was never published, and a ribbon that never rendered.
- **Dummy secrets in tests are assembled at runtime** (`['pat', 'ap1', …].join('-')`):
  GitHub push protection rejects a push containing anything shaped like a real key, even a fake.
- **A required new setting breaks infra CI too:** its "Real site image runs behind the gateway"
  job starts the real `:staging` integrations image with its own settings file
  (`.github/workflows/ci.yml`). Add the setting there in the same change (as for
  `EMAIL_ALLOWLIST`, 29 Oct).
- **The stop hook may say a branch is unpushed** when it's pushed but its tracking ref wasn't
  fetched: `git fetch origin <branch>` clears it.

## What the build session can't do (GitHub proxy limits)

These need Attila, so give him exact click-paths or commands:

- create or delete **tags/releases** (releases: GitHub → Releases → Draft new release);
- change **repo settings / rulesets** (send importable ruleset JSON instead);
- **delete branches**;
- read some Actions/package APIs (job logs and artifacts return 403): make CI print failures
  as `::error` annotations, then read them from the check-run annotations API. Job
  conclusions and check-runs are readable;
- post comments that act on a bot, such as `@dependabot recreate` or `@dependabot rebase`:
  comments made through the session's GitHub tool are altered and get a footer appended, so
  the command doesn't work. Give Attila the exact text and the PR; he posts it as its own
  comment;
- run everything locally. As of 22 Oct 2026 the **npm registry is reachable** (pnpm installs,
  and `npm i node@26` into a scratch folder gives a usable Node 26), so lockfiles can be
  created and refreshed in the session with `pnpm install --lockfile-only`; the old
  temporary-workflow trick is no longer needed. But there is **no Docker daemon**, and the
  Playwright browser download and Docker Hub are not reachable, so `test:e2e`,
  `check:lighthouse` and the image build and Trivy scan run only in CI. Lint, `check`,
  `test:unit`, build, `check:secrets` and `check:links` do run in the session (site CI uses
  Node 26; a session on Node 22 is close enough for these);
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
  `picklemypaddle-site-smoke:<sha>`). A `vX.Y.Z` release re-tags without rebuilding. The
  publish step fails unless every image is readable back from GHCR. All three GHCR
  packages are public (home-server pulls anonymously).
- Shared steps that pipe through `tee` must `set -o pipefail` (fixed 13 Oct; before that, test
  failures never failed a job). Failures surface as `::error` annotations. In infra CI the
  site smoke suite (`EXPECT_STAGING=1`, through the gateway) annotates its failing tests,
  which is the quickest way to see why home-server rolled back.
- **Site `.trivyignore` expires 2 Nov 2026** (SCRUM-38, SCRUM-60; extended from 26 Oct by site PR #40). It accepts, for a limited
  time, the HIGH findings in the `caddy:2-alpine` base image: the Go 1.26.9 / x/net 0.60.0 set
  from 11 Oct and `CVE-2026-111943` (fixed in Go 1.26.10 / 1.27.3, 20 Oct). Remove it once a
  Caddy release built with Go 1.26.10 or later is out, or re-review the expiry with Attila.
  The site's `caddy-base-check.yml` scans the base image every Monday 08:30 Sydney time
  (without the ignore file) and leaves a `caddy-base-clean` or `caddy-base-vulnerable`
  annotation on the run; when it says clean, delete the `.trivyignore` block and that workflow
  together. A weekly scheduled task watches for this and prepares the removal. Once that is
  done, delete this bullet and the matching row in `as-built.md`.
- **Dependabot and the 3-day gate (site, SCRUM-59).** The npm updater runs pnpm with a
  3-day release-age gate over **every entry in `pnpm-lock.yaml`**, not just the version it is
  bumping. If the lockfile pins anything published in the last 3 days, every run fails with
  `ERR_PNPM_NO_MATCHING_VERSION` (and the PRs show "can't resolve your JavaScript dependency
  files") until that version is 3 days old. This happened 21 to 22 Oct 2026 after the lockfile
  was regenerated for `lighthouse`. Our own installs had no gate, so CI stayed green and the
  problem was invisible there. The site's `pnpm-workspace.yaml` therefore sets
  `minimumReleaseAge: 4320` (3 days), so a regenerated lockfile always passes. To use a newer
  release sooner, add the package to `minimumReleaseAgeExclude`, knowing Dependabot can fail
  for up to 3 days. If it does fail: find the lockfile entries inside the 3-day window by
  comparing them with registry publish times, and move them to older versions the dependency
  ranges allow (temporary `overrides`, regenerate, then remove the overrides), as in site PR
  #38. Where Dependabot's 3-day default comes from is not confirmed. Attila checks the result
  under Insights → Dependency graph → Dependabot → **Check for updates**. Dependabot rebases
  its own PRs when `main` moves, so don't edit its branches; a PR that conflicts after a
  sibling merges fixes itself within a minute or two.

## Staging (home-server, 192.168.1.24, Ubuntu)

- http://home-server:8088: the gateway routes `/api/*` to integrations, everything else to
  the site. `/version.txt` shows the live site commit.
- **home-server's CPU predates x86-64-v2** (no SSE4.2; Core 2 class). Native code built for v2
  crashes there although CI (newer runners) passes: sharp's prebuilt binaries did on 26 Oct 2026
  (SCRUM-66), so integrations uses Alpine's libvips tools instead. Check any new native dependency
  or base image against this. integrations' container test runs the image under QEMU
  `-cpu Penryn` to catch it; QEMU's `qemu64` model is too old even for Node, so use Penryn.
- **Blog editor (SCRUM-34):** Keystatic, staging only, Tailscale only:
  `https://home-server.tail8bc7ae.ts.net:8444/keystatic` → Tailscale Serve → the gateway's
  second listener (`:8081`, published on `127.0.0.1:8101` only) → `editor:4321`. The LAN
  listener 404s `/keystatic*` and `/api/keystatic*`. Its image (`picklemypaddle-site-editor`)
  is built from the site's `Dockerfile.editor` + `astro.editor.config.mjs`; the public build
  (`astro.config.mjs`) and the production stack never include it, and CI checks both. Posts
  are saved on `blog/…` branches and published by PR. Its GitHub status is
  `staging/home-server/editor` (a service's `com.picklemypaddle.status-context` label), so it
  never overwrites the site's `staging/home-server`. Shared `image.yml` publishes it through
  `staging-extra-images` (`:<sha>` and `:staging`). If the tailnet name or port 8444 changes,
  the GitHub App callback URL, `EDITOR_HOST`/`EDITOR_PORT` in `Dockerfile.editor` and the
  staging `.env` must change together.
- A pull-based updater (systemd timer, 2 min) deploys, health-checks, runs the smoke tests
  and rolls back on failure. It posts the result as a `staging/home-server` commit status.
  Full detail is in `runbooks/staging-home-server.md`.
- **Order database (SCRUM-64):** Postgres 18 on an internal network only integrations joins,
  started by the updater before any update (labelled `com.picklemypaddle.dependency`), backed up
  nightly. Its password is made once by `install.sh`; never regenerate it while the volume exists.
- **Order smoke test (SCRUM-68):** after each site deploy the smoke suite places a real 1-paddle
  order from `smoke+<run>@example.com` and expects a `PMP-` reference with `test: true`. Outside
  production `@example.com` orders are deleted after 24 h. Staging allows 60 orders per IP per
  hour (everything arrives from the Docker bridge address); production keeps 5 and the service
  refuses to start with a relaxed limit.
- Changes to `staging/` take effect only after `git pull && sudo ./staging/install.sh` on
  home-server (`--check` warns when the installed files are stale). `install.sh` restarts the
  gateway before the first update: a running gateway keeps its old Caddyfile until it is
  recreated. Hand-run compose commands need `-f compose.staging.yml` from
  `/opt/picklemypaddle/staging`.
- A build that failed its checks is remembered as known-bad and not retried. To retry:
  `sudo rm -f /var/lib/pmp-staging/site.known-bad && sudo systemctl start
  pmp-staging-update.service` (the smoke run takes about 6 min).
- Secrets live only on home-server (root, 600): `/etc/picklemypaddle/github-status.token`
  and `/etc/picklemypaddle/integrations.env` (test-mode keys only).
- **NSW public holidays (SCRUM-73)** live in integrations `src/orders/holidays.ts` (nsw.gov.au,
  two years ahead). Its coverage test fails once they don't reach 12 months ahead: add the next
  year then, not by guessing.
- **Order admin (SCRUM-71/72):** `https://home-server.tail8bc7ae.ts.net:8445/admin` (tailnet only)
  → Tailscale Serve → the gateway's third listener (`:8082`, published on `127.0.0.1:8100` only) →
  `integrations-admin:8081` over the internal `pmp-staging-admin` network. The LAN listener 404s
  `/admin*`. integrations believes `Tailscale-User-Login` only from the gateway on that network and
  lets in only `ADMIN_LOGINS` (root-only secrets file; `install.sh --set-admin-logins`). Production:
  `https://pmp-prod.tail8bc7ae.ts.net/admin` (Serve on the tailnet's 443 → `127.0.0.1:8100`),
  503 until orders are on. In tests and CI, fake the identity headers on the loopback listener
  (`tests/helpers/admin.ts`, `tests/e2e/server.ts`).
- **Tailscale (SCRUM-38):** staging is also at `https://home-server.tail8bc7ae.ts.net:8443`
  (tailnet only, never Funnel), via `install.sh --tailscale` / `--tailscale-off`. Port 443
  on that name serves another app (`localhost:3000`): never touch it. CORS origins are
  `STAGING_SITE_ORIGINS` (comma-separated); `STAGING_PUBLIC_URL` is only the status link.
- **Staging-only behaviour lives in the gateway:** noindex, `robots.txt`, and `/env.css`,
  which reveals the site's `[data-env="staging-only"]` elements (Preview ribbon, test-order
  notice). The image is identical for production, so never bake staging behaviour into the
  build. Smoke runs through the gateway set `EXPECT_STAGING=1`. Staging CSS in `/env.css`
  must sit in `@layer base`: Tailwind v4 hides `[hidden]` with a layered `!important` rule,
  which beats any unlayered rule. In the Caddyfile, `respond` treats a first argument starting
  with `@` or `/` as a matcher, so use `respond * "…" 200`.

**Testing the integrations service in the session:** `pnpm test` runs on PGlite (Postgres in
WebAssembly). To run the built `dist/server.js` or the suite through the real `pg` driver, start
PGlite's wire-protocol server from a scratch folder (`npm i @electric-sql/pglite
@electric-sql/pglite-socket`, then its `dist/scripts/server.js -p 5544 -m 8`) and point
`DATABASE_URL`/`TEST_DATABASE_URL` at `postgres://postgres:x@127.0.0.1:5544/postgres`. A Caddy binary
from GitHub releases runs here too, so gateway configs can be validated and exercised locally.
The shared order rules live in integrations `src/orders/rules.ts`; the site's
`src/lib/order-rules.ts` is a byte-identical copy that its tests compare with integrations `main`.

## Production (OVH VPS-1, Sydney; SCRUM-19)

- **On the tailnet** as `pmp-prod` (`tag:pmp-prod`, key expiry off, no Tailscale SSH; SCRUM-71). The
  tailnet policy lets Attila's devices reach it on TCP 443 only, and nothing reach out from it.

- https://www.picklemypaddle.com (the bare domain redirects to it). A Caddy gateway with automatic
  HTTPS in front of the site. Integrations and Postgres are defined but **orders are off**: they sit
  in the `orders` profile and the gateway answers `/api/*` with 503 until `PMP_ORDERS=open`
  (production runbook, "Switching orders on"; only after SCRUM-8, SCRUM-21 and SCRUM-75). Stack in `production/`, detail in
  `runbooks/production-ovh-vps.md`. Cloudflare DNS is **DNS only** (not proxied) so Caddy can get
  its certificates.
- **Nothing deploys itself.** Attila runs `sudo /opt/picklemypaddle/production/update.sh deploy
  vX.Y.Z` on the VPS; it shows the change, asks, health-checks, checks the live site and rolls back
  on failure. Production runs release tags (`vX.Y.Z`) only, never `:staging`. A release is a GitHub
  Release on the site repo (Attila publishes it; the session can't create tags).
- **One gateway, several websites.** The Caddy gateway serves every site on the VPS: one file each in
  `production/gateway/sites/`, each site its own Compose project and private network (Attila plans a
  consulting/showcase site, possibly a third; not AdventureLog, which stays on home-server via
  Tailscale). Steps: "Adding another website" in the production runbook. Static or light sites only
  (2 vCores, 4 GB). This repo may be split or renamed once the consulting site is built.
- The VPS can't be reached from the session: Attila pastes command output, as for home-server.
- Production-only behaviour lives in `production/`; the site image is the same one staging runs.
  The site image bakes in `SITE_URL`, so it is built with the production address (site PR #31);
  releases must be cut from a commit that includes it. `update.sh` refuses (and rolls back) any
  release whose pages still name `home-server`.
- Secrets (when integrations arrive) go in `/etc/picklemypaddle/integrations.env` on the VPS (root,
  600), live keys only, same pattern as staging.

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
  Tailscale, with posts in `src/content/blog/<lang>/` (English at `/blog/<slug>`, other
  languages at `/<lang>/blog/<slug>`; languages listed in the site's `src/config/i18n.ts`).
- Agents draft and Attila approves; nothing is sent or paid automatically.

### Orders (SCRUM-8, decided 26 Oct 2026; detail in SCRUM-64 to 75)

- **Order of record:** the integrations service's own **PostgreSQL**, one Postgres per app (each
  Compose project its own; Umami v3 needs Postgres too). Photos are files on a private volume,
  never in the database or behind a public URL. Backups are nightly `pg_dump` plus a photo copy,
  kept **30 days** at most (off-site target: SCRUM-44).
- **Admin is the master**, reachable only over Tailscale (the VPS joins the tailnet; Tailscale
  Serve plus a `Tailscale-User-Login` check; never Funnel). **HubSpot is a one-way mirror**:
  contact (no street address) and one deal per order, stage = status; edits made in HubSpot are
  overwritten. Test portal only until near go-live; the production portal must be in the
  Australian region (the privacy policy says so).
- **Statuses:** Submitted → Questions → Accepted → Paid → In queue → Re-gritted → Posted back →
  Completed, plus Rejected, Withdrawn, Lapsed. Paid is set by Stripe (SCRUM-9); staging has a
  test-only "Mark paid (test)". Completed is automatic 10 days after Posted back; Lapsed after
  30 days stalled in Questions (unpaid lapse: SCRUM-9).
- **Emails** (Resend) at key moments only: Submitted, Accepted, In queue, Posted back, Rejected.
  From sales@, Reply-To info@; questions to customers go by hand from info@. Attila's alert has
  the reference and admin link only. Outside production: `[TEST]` subjects and an allow-list of
  Attila's addresses (everything else suppressed). Built (SCRUM-69) as an outbox: queued with the
  change, sent by a worker, retried; rendered at send time with a token minted per send (no token
  at rest). Production won't start while a template has `[To confirm: …]`.
- **Status changes** go through integrations `src/orders/transitions.ts` (built 28 Oct with
  SCRUM-69; the admin UI is SCRUM-72), which also queues the email and, with SCRUM-74, the CRM sync.
- **Testimonials (decided 28 Oct):** the Posted back email links to a short review form on the
  private status page (text, first name and suburb pre-filled, a permission checkbox), stored with
  the permission; Attila adds approved ones to the site by PR. No separate later email for now;
  revisit after go-live.
- **Status page:** minimal (no name, address, phone, email or photos); token in the URL
  fragment, stored hashed; expires 90 days after Completed (30 days after Rejected or Lapsed).
  "Email me my links" never reveals whether an address is known. References look like
  `PMP-7K3QX`. "Back in the post by" = arrival + 10 NSW business days, plus queue position.
- **Photos:** resized to 2560 px in the browser; HEIC left to iOS (not accepted); re-encoded
  with all metadata stripped on the server; 10 MB per photo, 60 MB per request.
- **Abuse:** honeypot, 3-second minimum fill time, 5 orders per IP per hour and 3 per email per
  day (configurable per environment; production never relaxed for tests). No third-party
  CAPTCHA (CSP).
- **Retention:** a daily automatic job, with a 14-day heads-up and per-order extensions in
  admin. Photos: 12 months after Completed. Rejected, Withdrawn and Lapsed orders: deleted
  12 months later. Paid orders: 5 years. Erasure on request keeps only the tax minimum for paid
  orders and permanently deletes the HubSpot contact. Gmail and Resend are covered by the
  deletion runbook. SCRUM-75 must be Done before production takes real orders.
- **Clubs** (batch tracking) are in SCRUM-10, not SCRUM-8.
