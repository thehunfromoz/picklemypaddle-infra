# picklemypaddle-infra

Deployment and shared CI for Pickle My Paddle. Jira epic: SCRUM-6.

Planned contents (built under SCRUM-15/16/17/18):

- `staging/`: Docker Compose for home-server (192.168.1.24), Caddy routing, a pull-based
  updater (systemd timer) that pulls new `:staging` images from GHCR, health checks and
  automatic rollback, and smoke tests that report a commit status back to GitHub.
- `production/`: OVH VPS setup (parked until staging sign-off; SCRUM-19/20).
- `.github/workflows/`: reusable workflows the component repos call.
- `runbooks/`: anything that can't be automated, written down step by step.

Staging uses a pull model on purpose: the repos are public, so nothing on the LAN runs
code triggered from GitHub.
