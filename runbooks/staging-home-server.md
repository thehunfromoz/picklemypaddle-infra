# Staging on home-server: setup and day-to-day

Jira: SCRUM-16. Staging lives at **http://home-server:8088**.

## How it works

```
GitHub (merge to main) ─► CI tests ─► GHCR  ghcr.io/thehunfromoz/picklemypaddle-site:staging
                                             ▲ pulled every 2 min
home-server ── pmp-staging-update.timer ─► update.sh ─► docker compose (project "pmp-staging")
                                                             gateway :8088 ─► site
```

- **Pull, not push.** home-server checks GHCR every 2 minutes. GitHub never connects to
  your LAN, and home-server never runs code from the public repos, only images that
  passed CI.
- **Health check and rollback.** A new image has to pass its Docker health check
  (`/healthz`) within 2 minutes. If it doesn't, the previous image is restored and the bad
  one is remembered, so it won't be retried every 2 minutes.
- **Port 8088, not 80/443.** Tailscale holds 443 on its own address and other containers
  share the box, so staging keeps to its own port. Change `STAGING_PORT` in
  `/opt/picklemypaddle/staging/.env` if you ever need to.
- Everything runs in its own Compose project (`pmp-staging`) and network, separate from
  your other containers.

## One-time setup

### 1. Make the site image public on GHCR (once)

home-server pulls without logging in. On github.com go to your profile → **Packages** →
**picklemypaddle-site** → **Package settings** → **Change visibility** → **Public**.
(The repo is already public, so this exposes nothing new.) The infra CI job "Real site
image runs behind the gateway" fails with a clear message until this is done.

### 2. Install on home-server

```bash
ssh home-server
git clone https://github.com/thehunfromoz/picklemypaddle-infra.git ~/picklemypaddle-infra
cd ~/picklemypaddle-infra
sudo ./staging/install.sh --check    # pre-flight only: Docker, port 8088 free, image pullable
sudo ./staging/install.sh            # installs to /opt/picklemypaddle/staging and starts it
```

The installer copies the files to `/opt/picklemypaddle/staging`, so the checkout in your
home folder is only a source to review and install from.

### 3. Reach it from the Mac

```bash
ping -c1 home-server
```

- **If it answers**, open http://home-server:8088. The answer may come from router DNS, Bonjour,
  or Tailscale MagicDNS (a `100.x` address). Staging listens on all of these.
- **If it doesn't answer**, add a hosts entry on the Mac:
  ```bash
  echo "192.168.1.24  home-server" | sudo tee -a /etc/hosts
  ```

## Day to day

| I want to… | Run on home-server |
| --- | --- |
| See if updates are working | `systemctl list-timers pmp-staging-update.timer` and `systemctl status pmp-staging-update.service` |
| Read the update log | `journalctl -u pmp-staging-update.service --since today` |
| Update now, not in 2 min | `sudo systemctl start pmp-staging-update.service` |
| See what's running | `sudo docker compose -p pmp-staging ps` |
| See site/gateway logs | `sudo docker compose -p pmp-staging logs --tail 50 site` |
| List deploy history | `sudo cat /var/lib/pmp-staging/site.deployed` |

### Roll back by hand

The image that ran before the current one is kept as `:previous`:

```bash
sudo docker tag ghcr.io/thehunfromoz/picklemypaddle-site:previous ghcr.io/thehunfromoz/picklemypaddle-site:staging
sudo docker compose --project-directory /opt/picklemypaddle/staging -f /opt/picklemypaddle/staging/compose.staging.yml up -d --pull never site
```

The next timer run pulls the latest `:staging` from GHCR again, so to *stay* on the old one,
stop the timer first: `sudo systemctl stop pmp-staging-update.timer` (start it again
when done).

### Retry an image that was marked bad

```bash
sudo rm /var/lib/pmp-staging/site.known-bad
sudo systemctl start pmp-staging-update.service
```

### Apply changes from this repo

Changes to the compose file, gateway or updater are never picked up automatically:

```bash
cd ~/picklemypaddle-infra && git pull
git log -p ORIG_HEAD..HEAD -- staging/    # review what changed
sudo ./staging/install.sh
```

### Remove staging

```bash
sudo systemctl disable --now pmp-staging-update.timer
sudo docker compose -p pmp-staging down
sudo rm /etc/systemd/system/pmp-staging-update.{service,timer} && sudo systemctl daemon-reload
sudo rm -r /opt/picklemypaddle/staging /var/lib/pmp-staging
```

## Acceptance checks (SCRUM-16)

1. Port check: `sudo ./staging/install.sh --check` shows "port 8088 is free".
2. Merge a visible change to the site, then within 5 minutes it appears on
   http://home-server:8088. Confirm with `journalctl -u pmp-staging-update.service` ("is healthy
   and live").
3. Broken image is rolled back: covered by the infra CI job "Updater deploys, rolls back and
   recovers", which publishes a deliberately broken image and checks staging stays on the
   previous version.
4. Mac loads http://home-server:8088.
