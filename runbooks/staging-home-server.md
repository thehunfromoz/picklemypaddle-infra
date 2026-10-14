# Staging on home-server: setup and day-to-day

Jira: SCRUM-16. Staging lives at **http://home-server:8088** on the LAN and, for club demos,
at **https://home-server.tail8bc7ae.ts.net:8443** on your tailnet (SCRUM-38, see
[Club demos over Tailscale](#club-demos-over-tailscale-scrum-38)).

## How it works

```
GitHub (merge to main) ─► CI tests ─► GHCR  ghcr.io/thehunfromoz/picklemypaddle-site:staging
                                             ▲ pulled every 2 min
home-server ── pmp-staging-update.timer ─► update.sh ─► docker compose (project "pmp-staging")
                                                             gateway :8088 ─► site
```

- **Two services behind one address.** The gateway sends `/api/*` to the integrations service
  (orders, CRM, payments) and everything else to the site. Both update themselves the same way.
- **Pull, not push.** home-server checks GHCR every 2 minutes. GitHub never connects to
  your LAN, and home-server never runs code from the public repos, only images that
  passed CI.
- **Smoke tests.** Once the health check passes, the updater runs the Playwright tests built
  from the same commit (`picklemypaddle-site-smoke:<commit>`) against staging through the
  gateway. If they fail, staging rolls back exactly as for a failed health check.
- **Results on GitHub.** Each deploy posts a `staging/home-server` status on its commit:
  pending → ✓ passed, or ✗ with the reason and the version it rolled back to. GitHub never
  connects in: home-server sends the result out with a token that can only write commit
  statuses.
- **Health check and rollback.** A new image has to pass its Docker health check
  (`/healthz`) within 2 minutes. If it doesn't, the previous image is restored and the bad
  one is remembered, so it won't be retried every 2 minutes.
- **Port 8088, not 80/443.** Tailscale holds 443 on its own address and other containers
  share the box, so staging keeps to its own port. Change `STAGING_PORT` in
  `/opt/picklemypaddle/staging/.env` if you ever need to.
- Everything runs in its own Compose project (`pmp-staging`) and network, separate from
  your other containers.

## One-time setup

### 1. Make the images public on GHCR (once)

home-server pulls without logging in. On github.com go to your profile → **Packages**, and
for **each** of these: **Package settings** → **Change visibility** → **Public**.

- **picklemypaddle-site**
- **picklemypaddle-site-smoke**: the site's smoke tests. While it's private, every deploy
  reports "smoke tests could not run".
- **picklemypaddle-integrations**

(The repos are already public, so this exposes nothing new.) The infra CI job "Real site
image runs behind the gateway" fails with a clear message until all three are public.

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

### 3. Let home-server post results to GitHub (once a year)

1. On github.com: profile picture → **Settings** → **Developer settings** → **Personal access
   tokens** → **Fine-grained tokens** → **Generate new token**.
   - Name: `home-server staging status`
   - Expiration: 1 year (put a reminder in your calendar)
   - Repository access: **Only select repositories** → `picklemypaddle-site` and
     `picklemypaddle-integrations` (to add a repo to an existing token: open the token → **Edit**
     → Repository access → add it → **Update**; the token value stays the same)
   - Permissions → Repository permissions → **Commit statuses: Read and write**. Leave
     everything else at "No access". GitHub adds read-only Metadata automatically.
2. Copy the token, then on home-server:
   ```bash
   cd ~/picklemypaddle-infra && sudo ./staging/install.sh --set-token
   ```
   Paste when asked (it isn't shown). It's checked with GitHub and saved to
   `/etc/picklemypaddle/github-status.token`, readable by root only. Never commit or share it.

Without a token everything still works. The results just don't show on GitHub. When the token
expires, `install.sh --check` warns you; repeat these steps to replace it.

### 4. API keys for the integrations service (when Stripe/HubSpot are built)

Staging keeps the integrations service's keys in **`/etc/picklemypaddle/integrations.env`**.
`install.sh` creates it empty, owned by root with mode 600, and `--check` fails if anyone loosens
those permissions. Nothing else on home-server, and nothing in any repo, holds these keys.

- **Only test-mode values on staging.** Use a Stripe *test* secret key (`sk_test_…`) and webhook
  secret, and a service key from the HubSpot *test* portal ("PickleMyPaddle test"). HubSpot's new
  accounts have no legacy private apps; create the key under Settings → Integrations → Service Keys
  with contacts, companies and deals read/write plus their schema scopes. The service refuses to
  start with a live Stripe key on staging. The error names the setting but never shows the key.
- Edit it with `sudo nano /etc/picklemypaddle/integrations.env`, then apply with
  `cd ~/picklemypaddle-infra && sudo ./staging/install.sh`.
- `APP_ENV`, `PORT` and `PUBLIC_SITE_ORIGIN` are fixed in `compose.staging.yml`, so this file
  can't switch staging to production settings.
- To check what the service sees, without values: `curl -s http://localhost:8088/api/status`.
- If the service won't start, `sudo docker compose -p pmp-staging logs --tail 20 integrations`
  lists every missing or invalid setting by name.

| Environment | Where its keys live |
| --- | --- |
| Your Mac (dev) | `.env` in each repo checkout (git-ignored), copied from `.env.example` |
| Staging | `/etc/picklemypaddle/integrations.env` on home-server (root, 600) |
| Production (later) | the same pattern on the OVH server, with live keys |

### 5. Reach it from the Mac

```bash
ping -c1 home-server
```

- **If it answers**, open http://home-server:8088. The answer may come from router DNS, Bonjour,
  or Tailscale MagicDNS (a `100.x` address). Staging listens on all of these.
- **If it doesn't answer**, add a hosts entry on the Mac:
  ```bash
  echo "192.168.1.24  home-server" | sudo tee -a /etc/hosts
  ```

## Club demos over Tailscale (SCRUM-38)

Open staging on your phone, iPad or laptop from anywhere, including over mobile data at a
club, at **https://home-server.tail8bc7ae.ts.net:8443**. Only devices signed in to your
tailnet can reach it. Nothing is exposed to the public internet (no Funnel).

What makes it safe to show:

- **Preview ribbon** at the top of every page, and a **test-order notice** above the order
  form. The staging gateway switches these on; the live site never shows them.
- **Not indexed:** every response carries `X-Robots-Tag: noindex, nofollow` and
  `/robots.txt` disallows everything.
- **No real payments:** the integrations service refuses live Stripe keys on staging.

### Turn it on (once)

Before the first time, in the Tailscale admin console → **DNS**: MagicDNS and **HTTPS
Certificates** are on (they already are if the app on port 443 uses HTTPS).

```bash
cd ~/picklemypaddle-infra && git pull
sudo ./staging/install.sh               # applies the gateway and updater changes first
sudo ./staging/install.sh --tailscale
```

It lists your existing Serve settings, refuses to go ahead if port 8443 is taken or
Funnel is on, adds `https://…:8443 → http://127.0.0.1:8088`, then checks that nothing
else changed (if anything did, it undoes its own change). It then:

- adds the tailnet address to `STAGING_SITE_ORIGINS`, so `/api` accepts calls from it;
- points `STAGING_PUBLIC_URL` (the link on the GitHub ✓) at it;
- checks the address itself: valid certificate, noindex, security headers, ribbon, `/api`.

The setting survives reboots. Running it again changes nothing. The port is
`TAILSCALE_HTTPS_PORT` in `/opt/picklemypaddle/staging/.env`.

### Add a phone or iPad

1. Install **Tailscale** from the App Store (or Google Play).
2. Sign in with the **same account** as home-server, and allow the VPN configuration.
3. In the Tailscale admin console → **Machines**, approve the device if asked. To stop it
   needing a fresh login every few months, open the device's **⋯** menu → **Disable key
   expiry**.
4. Switch Tailscale on and open https://home-server.tail8bc7ae.ts.net:8443 in Safari.
   Share → **Add to Home Screen** gives you a one-tap icon for demos.

Only add your own devices. A club's laptop or phone should look over your shoulder, not
join your tailnet.

### Before a club visit

- [ ] Phone: Tailscale **on**, **Wi-Fi off**, open the home-screen icon. The Preview ribbon
      shows.
- [ ] It's the version you want to show: the latest site commit on GitHub has a green
      `staging/home-server` ✓ (or compare `/version.txt` with the commit).
- [ ] Skim each page for `[To confirm: …]` placeholders you'd rather not show, and the
      order form for the test-order notice.
- [ ] home-server is on and online: the Tailscale app lists it as connected.
- [ ] Phone charged; a few screenshots saved in Photos in case the venue has no signal.

### Turn it off

```bash
sudo ./staging/install.sh --tailscale-off
```

This removes only port 8443 from Tailscale Serve. The app on 443 and the LAN address
http://home-server:8088 keep working, and the GitHub links go back to the LAN address.
To shut out a single lost device instead, remove it in the admin console → **Machines**.

### If something's wrong

| Symptom | Fix |
| --- | --- |
| Phone: "server can't be found" | Tailscale isn't connected on the phone, or "Use Tailscale DNS" is off in its settings. |
| Certificate warning, or the first load hangs | The first certificate can take a minute. Check HTTPS Certificates are enabled (DNS page), then re-run `--tailscale`. |
| No Preview ribbon | The gateway change isn't applied: `sudo ./staging/install.sh`. |
| `--tailscale` says the integrations image predates SCRUM-38 | Pages work; `/api` from the tailnet address starts working after integrations updates (merge its SCRUM-38 PR). |

Good to know: certificates are public records, so the name `home-server.tail8bc7ae.ts.net`
is visible in certificate-transparency logs (it already was, because of the app on 443).
The name only resolves to a tailnet address that nobody outside your tailnet can connect to.

## Day to day

| I want to… | Run on home-server |
| --- | --- |
| See if updates are working | `systemctl list-timers pmp-staging-update.timer` and `systemctl status pmp-staging-update.service` |
| Read the update log | `journalctl -u pmp-staging-update.service --since today` |
| Update now, not in 2 min | `sudo systemctl start pmp-staging-update.service` |
| See what's running | `sudo docker compose -p pmp-staging ps` |
| See site/gateway logs | `sudo docker compose -p pmp-staging logs --tail 50 site` |
| List deploy history | `sudo cat /var/lib/pmp-staging/site.deployed` |
| See the last smoke-test run | `sudo cat /var/lib/pmp-staging/site.smoke.log` |
| See results on GitHub | the ✓/✗ next to each commit on the `picklemypaddle-site` commits page |

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

### Apply changes from this repo (and refresh the gateway)

Changes to the compose file, gateway or updater are never picked up automatically. Re-running
the installer also pulls the latest Caddy image for the gateway, so do it every month or so
even without changes:

```bash
cd ~/picklemypaddle-infra && git pull
git log -p ORIG_HEAD..HEAD -- staging/    # review what changed
sudo ./staging/install.sh                 # the full install; --check and --set-token don't apply changes
```

`sudo ./staging/install.sh --check` warns "installed files differ from this checkout" when
you've pulled changes but haven't installed them yet.

### Remove staging

```bash
sudo systemctl disable --now pmp-staging-update.timer
sudo docker compose -p pmp-staging down
sudo rm /etc/systemd/system/pmp-staging-update.{service,timer} && sudo systemctl daemon-reload
sudo rm -r /opt/picklemypaddle/staging /var/lib/pmp-staging
```

## Acceptance checks (SCRUM-38)

1. **CI (infra):** the `Lint scripts and compose file` job shellchecks `staging/tailscale.sh`,
   unit-tests the Serve config checks (`tests/tailscale_serve_test.py`) and runs
   `--tailscale` / `--tailscale-off` against a stand-in `tailscale` (`tests/tailscale.test.sh`:
   :443 untouched, no Funnel, conflicts refused, changes undone). The `Real site image runs
   behind the gateway` job checks noindex, `robots.txt` and `/env.css`, and runs the site's
   smoke tests with `EXPECT_STAGING=1`.
2. **On home-server:** `sudo ./staging/install.sh --tailscale` ends with "Done", and
   `tailscale serve status` shows the 443 app unchanged plus `:8443 → 127.0.0.1:8088`, with no
   Funnel.
3. **Phone demo:** on mobile data with Wi-Fi off, open the address, browse every page (ribbon
   on each), go to the order form and see the test-order notice.
4. **Private:** on a device not on the tailnet (or the phone with Tailscale switched off), the
   address doesn't resolve or doesn't connect.
5. The `staging/home-server` ✓ on GitHub links to the tailnet address.

## Acceptance checks (SCRUM-17)

1. Merge a site change. The commit first shows `staging/home-server` pending, then ✓ within
   about 5 minutes.
2. A failing smoke test or health check shows ✗ ("Smoke tests failed; staging rolled back to
   …") and staging keeps serving the previous version. Both are covered by the infra CI job
   "Updater deploys, rolls back and recovers" using a fake GitHub API.

## Acceptance checks (SCRUM-16)

1. Port check: `sudo ./staging/install.sh --check` shows "port 8088 is free".
2. Merge a visible change to the site, then within 5 minutes it appears on
   http://home-server:8088. Confirm with `journalctl -u pmp-staging-update.service` ("is healthy
   and live").
3. Broken image is rolled back: covered by the infra CI job "Updater deploys, rolls back and
   recovers", which publishes a deliberately broken image and checks staging stays on the
   previous version.
4. Mac loads http://home-server:8088.
