# picklemypaddle-infra

> **Starting a new Claude session?** Read [docs/working-with-claude.md](docs/working-with-claude.md) first.

Deployment and shared CI for PickleMyPaddle. Jira epic: SCRUM-6.

Planned contents (built under SCRUM-15/16/17/18):

- `staging/` (SCRUM-16, built): Docker Compose for home-server (192.168.1.24) with a Caddy
  gateway on port 8088, and a pull-based updater (systemd timer, every 2 min) that pulls new
  `:staging` images from GHCR, health-checks them and rolls back automatically. Setup and
  day-to-day: [runbooks/staging-home-server.md](runbooks/staging-home-server.md).
  After each deploy it runs that build's smoke tests and posts a `staging/home-server`
  commit status to GitHub (SCRUM-17).
- `production/` (SCRUM-19): the OVH VPS stack: Docker Compose with a Caddy gateway that gets
  HTTPS certificates by itself for `picklemypaddle.com` and `www`, serving the site (integrations
  to follow); other websites can be added alongside it, one file each. There is **no auto-updater**: a person runs `update.sh deploy vX.Y.Z`, which shows the
  change, asks, health-checks, checks the live site and rolls back on failure. Production only runs
  release tags. Setup and day-to-day: [runbooks/production-ovh-vps.md](runbooks/production-ovh-vps.md).
- `runbooks/search-console-go-live.md` (SCRUM-36): the Google Search Console steps for launch day.
- `.github/workflows/`: shared CI the component repos call (SCRUM-13/15), so a fix lands everywhere at once:
  - `node-checks.yml`: install a pnpm/Node project (Node 22 unless `node-version` says otherwise) and run its checks (lint, type-check, tests…);
    each failure is summarised on the PR.
  - `secret-scan.yml`: gitleaks over the full history.
  - `image.yml`: build the Docker image, run the repo's container tests, Trivy scan. On merge to
    `main` it publishes `:staging` and `:<commit>` with revision and build-date labels, then prunes
    old commit tags (keeps 20; never `:staging` or version tags).
  - `release.yml`: on a `vX.Y.Z` git tag, points `:vX.Y.Z` at the image already built for that
    commit. Nothing is rebuilt, and a commit that never went through `main` can't be released.

  Callers use `uses: thehunfromoz/picklemypaddle-infra/.github/workflows/<file>@main`.
  Check names then read `<job> / <name>`, e.g. `checks / Checks`, `image / Image`.
- `tests/`: integration tests run in CI (e.g. the updater's deploy/rollback scenarios).
- `runbooks/`: anything that can't be automated, written down step by step.

Staging uses a pull model on purpose: the repos are public, so nothing on the LAN runs
code triggered from GitHub.
