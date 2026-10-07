# picklemypaddle-infra

Deployment and shared CI for Pickle My Paddle. Jira epic: SCRUM-6.

Planned contents (built under SCRUM-15/16/17/18):

- `staging/` (SCRUM-16, built): Docker Compose for home-server (192.168.1.24) with a Caddy
  gateway on port 8088, and a pull-based updater (systemd timer, every 2 min) that pulls new
  `:staging` images from GHCR, health-checks them and rolls back automatically. Setup and
  day-to-day: [runbooks/staging-home-server.md](runbooks/staging-home-server.md).
  After each deploy it runs that build's smoke tests and posts a `staging/home-server`
  commit status to GitHub (SCRUM-17).
- `production/`: OVH VPS setup (parked until staging sign-off; SCRUM-19/20).
- `.github/workflows/`: reusable workflows the component repos call.
- `tests/`: integration tests run in CI (e.g. the updater's deploy/rollback scenarios).
- `runbooks/`: anything that can't be automated, written down step by step.

Staging uses a pull model on purpose: the repos are public, so nothing on the LAN runs
code triggered from GitHub.
