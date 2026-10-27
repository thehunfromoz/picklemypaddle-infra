# Staging on home-server: setup and day-to-day

Jira: SCRUM-16. Staging lives at **http://home-server:8088** on the LAN and, for club demos,
at **https://home-server.tail8bc7ae.ts.net:8443** on your tailnet (SCRUM-38, see
[Club demos over Tailscale](#club-demos-over-tailscale-scrum-38)). The blog editor is only on
the tailnet, at **https://home-server.tail8bc7ae.ts.net:8444/keystatic** (SCRUM-34, see
[Blog editor over Tailscale](#blog-editor-over-tailscale-scrum-34)).

## How it works

```
GitHub (merge to main) ─► CI tests ─► GHCR  ghcr.io/thehunfromoz/picklemypaddle-site:staging
                                             ▲ pulled every 2 min
home-server ── pmp-staging-update.timer ─► update.sh ─► docker compose (project "pmp-staging")
                                                             gateway :8088 ─► site
                                                                     │       └► integrations (/api/*) ─► postgres
                                       (loopback only, for Tailscale) :8089 ─► editor (blog)
home-server ── pmp-staging-backup.timer (02:30) ─► backup.sh ─► /var/backups/picklemypaddle/staging
```

- **Two services behind one address.** The gateway sends `/api/*` to the integrations service
  (orders, CRM, payments) and everything else to the site. Both update themselves the same way.
- **The order database (SCRUM-64)** is a Postgres 18 that only integrations can reach (its own
  internal network, no published port). It is started before any update and never replaced by
  one; see "Order database" below.
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
- **picklemypaddle-site-editor**: the blog editor (SCRUM-34). It appears after the first site
  build that publishes it.

(The repos are already public, so this exposes nothing new.) The infra CI job "Real site
image runs behind the gateway" fails with a clear message until all four are public.

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

This removes only staging's ports from Tailscale Serve: 8443 and the blog editor's 8444
(SCRUM-34), so the editor is then unreachable. The app on 443 and the LAN address
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

## Blog editor over Tailscale (SCRUM-34)

Write and edit blog posts in a browser on any of your tailnet devices, phone included, at
**https://home-server.tail8bc7ae.ts.net:8444/keystatic**. It is Keystatic, signed in with
GitHub: posts are saved straight into `picklemypaddle-site` on a `blog/…` branch, and you
publish by merging the pull request, so CI and branch protection apply as for any change.

How it's kept private:

- **Tailscale only.** The gateway serves the editor on a second listener that is published on
  `127.0.0.1:8089` only, and Tailscale Serve forwards `:8444` there. The LAN address
  (`http://home-server:8088/keystatic`) answers 404, and nothing else on the network can
  reach port 8089.
- **Staging only.** The editor is its own image, `picklemypaddle-site-editor`, built from the
  site repo's `Dockerfile.editor`. The public site image never contains it (site CI fails if
  it answers `/keystatic`), and the production stack has no editor service (infra CI fails if
  `production/` mentions it).
- **GitHub decides who can edit.** Sign-in is through a GitHub App installed only on
  `picklemypaddle-site`; it can only do what your own GitHub account can do there.
- **Secrets stay on home-server:** the App's client ID and secret and the editor's cookie key
  live only in `/etc/picklemypaddle/editor.env` (root, 600).

### Set it up (once)

**1. Create the GitHub App** (on github.com, signed in as thehunfromoz):
your profile picture → **Settings** → **Developer settings** (bottom of the left menu) →
**GitHub Apps** → **New GitHub App**, then fill in:

| Field | Value |
| --- | --- |
| GitHub App name | `PickleMyPaddle Blog Editor` (its URL name becomes `picklemypaddle-blog-editor`; if GitHub says the name is taken, pick another and tell Claude the URL name, since the editor image shows it in one link) |
| Homepage URL | `https://github.com/thehunfromoz/picklemypaddle-site` |
| Callback URL | `https://home-server.tail8bc7ae.ts.net:8444/api/keystatic/github/oauth/callback` |
| Expire user authorization tokens | ticked (the default) |
| Request user authorization (OAuth) during installation | not ticked |
| Webhook → Active | **not** ticked (the editor doesn't use webhooks) |
| Repository permissions | **Contents: Read and write**, **Pull requests: Read and write** (Metadata: Read-only is added automatically). Nothing else. |
| Where can this GitHub App be installed? | **Only on this account** |

Then **Create GitHub App**. On the App's page:

- copy the **Client ID** (starts with `Iv`);
- **Generate a new client secret** and copy it (it's shown once). You don't need a private key.
- left menu → **Install App** → **Install** next to thehunfromoz → **Only select
  repositories** → `picklemypaddle-site` → **Install**.

**2. Make the editor image public** (once, after the site PR with the editor is merged and
CI has published it): profile → **Packages** → **picklemypaddle-site-editor** → **Package
settings** → **Change visibility** → **Public**, as for the other packages in step 1 above.

**3. On home-server:**

```bash
cd ~/picklemypaddle-infra && git pull
sudo ./staging/install.sh                   # adds the editor and its secrets file; LAN check: /keystatic is 404
sudo ./staging/install.sh --set-editor-app  # paste the Client ID, then the secret (hidden)
sudo ./staging/install.sh --tailscale       # adds https://…:8444 for the editor (8443 is unchanged)
```

`--set-editor-app` saves the two values in `/etc/picklemypaddle/editor.env`, restarts the
editor and checks it now sends sign-in to GitHub with your App. `--tailscale` refuses to
change anything if port 8444 is taken or has Funnel on, and undoes its own change if anything
else in Serve moved, exactly as for 8443. The editor's ports are `TAILSCALE_EDITOR_HTTPS_PORT`
and `EDITOR_LOCAL_PORT` in `/opt/picklemypaddle/staging/.env`; if you ever change 8444, the
GitHub App's callback URL and the editor image's `EDITOR_PORT` must change with it.

### Write and publish a post (phone or laptop)

1. Tailscale **on**. Open **https://home-server.tail8bc7ae.ts.net:8444/keystatic** (Share →
   **Add to Home Screen** for a one-tap icon). **Sign in with GitHub**; the first time, GitHub
   asks you to authorise *PickleMyPaddle Blog Editor*.
2. `main` is protected, so first make a branch: tap the branch name at the top → **New
   branch** → a short name such as `my-post` (it becomes `blog/my-post`).
3. **Blog (English)** → **Add**. Fill in the title (the web address is made from it), a summary
   of 70 to 160 characters (search results show it), the date, and the body; body headings
   start at Heading 2, because the title is the page's main heading. A cover image is optional; if you add one, its description (alt text)
   is required, and the build fails without it. Tick **Draft** to save without publishing.
   **Create** (later edits: **Save**). Each save is a commit on your branch.
4. When it's ready: branch menu → **Create pull request**. GitHub opens; tap **Create pull
   request**. CI checks the post (schema, links, accessibility, the built pages).
5. When the checks are green, **Merge** (GitHub app or web). Within about 10 minutes
   home-server deploys it: the post is at `https://home-server.tail8bc7ae.ts.net:8443/blog/<web-address>`
   and the merge commit gets a green `staging/home-server` ✓. It reaches the live site with the
   next release.
6. On the merged PR, **Delete branch** (Claude can't delete branches).

To take a post down, open it in the editor on a new branch and tick **Draft** (or **Delete**),
then pull request and merge as above.

### If something's wrong

| Symptom | Fix |
| --- | --- |
| `…:8444` doesn't load, `…:8443` does | The editor port isn't served: `sudo ./staging/install.sh --tailscale`. Check: `tailscale serve status` lists `:8444 → 127.0.0.1:8089`. |
| GitHub says "The redirect_uri is not associated with this application" | The App's **Callback URL** must be exactly the one in step 1. |
| Sign-in loops back to the start, or "missing client ID" | Re-run `sudo ./staging/install.sh --set-editor-app`. |
| Saving fails with a permissions or "protected branch" error | You're on `main`: make a branch first (step 2). If it's on a `blog/…` branch, check the App is installed on `picklemypaddle-site` with Contents: Read and write. |
| The PR's checks fail on the post | Open the failing check's annotation. The usual causes: a summary outside 70 to 160 characters, a top-level (Heading 1) heading in the body (the title is the page's only one, so start at Heading 2), or a cover image without a description. The editor now refuses the first two while you write (site PR #43), but a post started before that, or edited by hand, can still have them. Fix it in the editor on the same branch; the PR updates. |
| The editor shows an old version | It updates with the site; `sudo docker compose -p pmp-staging ps editor` shows its state. A failed editor image is rolled back like the site and reported as `staging/home-server/editor` on its commit. |

## Order database (SCRUM-64)

The integrations service's own Postgres is the order of record. On home-server:

| What | Where |
| --- | --- |
| Database | service `postgres` in the `pmp-staging` project, image `postgres:18-alpine`, database and user `pmp` |
| Its data | Docker volume `pmp-staging-pgdata` |
| Paddle photos | Docker volume `pmp-staging-photos` (mounted in integrations at `/data/photos`; nothing serves it) |
| Password | `/etc/picklemypaddle/postgres.env` (root, 600), made once by `install.sh` |
| `DATABASE_URL` | `/etc/picklemypaddle/integrations.env` (root, 600), written by `install.sh` to match |
| Nightly backups | `/var/backups/picklemypaddle/staging` (root, 700): `db-<time>.dump` and `photos-<time>.tar.gz`, kept 30 days |

- The schema is migrated by integrations when it starts. A failed migration means the new
  container never turns healthy, so the updater puts the previous image back.
- The updater starts postgres before any update. If postgres isn't healthy it updates nothing
  that round ("dependencies … are not healthy" in the journal), so no image is blamed for it.
- Postgres changes only when you re-run `install.sh` (like the gateway). A new **major** version
  is a deliberate change in `compose.staging.yml`, with a dump and restore.
- Never delete `/etc/picklemypaddle/postgres.env` on its own: the data volume only opens with
  that password, and `install.sh` refuses to invent a new one while the volume exists.

### Back up by hand

```bash
sudo /opt/picklemypaddle/staging/backup.sh          # what the 02:30 timer runs
sudo ls -lh /var/backups/picklemypaddle/staging
journalctl -u pmp-staging-backup.service --since -2d  # the nightly runs (counts and sizes only)
```

### Restore by hand

Into a scratch database first, to check a backup (this is the restore drill). Take a backup
first if tonight's hasn't run yet (`sudo /opt/picklemypaddle/staging/backup.sh`), and place a test
order beforehand so there's something to count:

```bash
cd /opt/picklemypaddle/staging
# The folder is root-only, so the wildcard must be expanded by root (sudo sh -c), not your shell.
f=$(sudo sh -c 'ls -t /var/backups/picklemypaddle/staging/db-*.dump | head -n1'); echo "$f"
sudo docker compose -p pmp-staging exec -T postgres psql -U pmp -d pmp -c 'CREATE DATABASE restore_check'
sudo cat "$f" | sudo docker compose -p pmp-staging exec -T postgres pg_restore -U pmp -d restore_check --no-owner
for db in pmp restore_check; do
  echo -n "$db: "; sudo docker compose -p pmp-staging exec -T postgres psql -U pmp -d $db -tAc 'select count(*) from orders'
done                                                  # the two counts should match
sudo docker compose -p pmp-staging exec -T postgres psql -U pmp -d pmp -c 'DROP DATABASE restore_check'
```

To replace the live database with a backup (staging only, everything since that backup is lost):

```bash
sudo systemctl stop pmp-staging-update.timer
sudo docker compose -p pmp-staging stop integrations
sudo cat "$f" | sudo docker compose -p pmp-staging exec -T postgres pg_restore -U pmp -d pmp --clean --if-exists --no-owner
p=$(sudo sh -c 'ls -t /var/backups/picklemypaddle/staging/photos-*.tar.gz | head -n1')
sudo cat "$p" | sudo docker run --rm -i -v pmp-staging-photos:/dst postgres:18-alpine sh -c 'rm -rf /dst/* && tar -C /dst -xzf - && chown -R 1000:1000 /dst'
sudo docker compose -p pmp-staging start integrations && sudo systemctl start pmp-staging-update.timer
```

### Reset staging's database (throw all test orders away)

```bash
sudo systemctl stop pmp-staging-update.timer
sudo docker compose -p pmp-staging rm -sf integrations postgres
sudo docker volume rm pmp-staging-pgdata pmp-staging-photos
sudo systemctl start pmp-staging-update.service   # recreates both, empty; integrations migrates on start
sudo systemctl start pmp-staging-update.timer
```

The password file stays, so the new database gets the same password.

### The order smoke test (SCRUM-68)

After each site deploy, the smoke tests place a real 1-paddle order through the gateway, from a
`smoke+<run>@example.com` address, and expect `201` with a `PMP-` reference and `test: true`.
Outside production, orders from `@example.com` are smoke orders: the service deletes them, with
their photos, 24 hours later. Staging allows 60 orders per IP per hour
(`STAGING_ORDER_LIMIT_PER_IP_HOUR` in `.env`), because the smoke tests, Tailscale visitors and your
own tests all reach the service from the same Docker bridge address; production keeps 5.

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
| See integrations/database logs | `sudo docker compose -p pmp-staging logs --tail 50 integrations postgres` |
| Check the order database | `curl -s http://home-server:8088/api/status` (`"database":{"reachable":true,…}`) |
| Count the test orders | `sudo docker compose -p pmp-staging exec -T postgres psql -U pmp -d pmp -c 'select status, count(*) from orders group by 1'` |
| Check the nightly backup | `systemctl list-timers pmp-staging-backup.timer` and `sudo ls -lh /var/backups/picklemypaddle/staging` |

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
sudo systemctl disable --now pmp-staging-update.timer pmp-staging-backup.timer
sudo docker compose -p pmp-staging down
sudo rm /etc/systemd/system/pmp-staging-{update,backup}.{service,timer} && sudo systemctl daemon-reload
sudo rm -r /opt/picklemypaddle/staging /var/lib/pmp-staging
# The test orders, photos and backups stay unless you also run:
#   sudo docker volume rm pmp-staging-pgdata pmp-staging-photos
#   sudo rm -r /var/backups/picklemypaddle/staging /etc/picklemypaddle/postgres.env
```

## Acceptance checks (SCRUM-64, SCRUM-68)

Once the infra PR is merged and installed (`git pull && sudo ./staging/install.sh`), then the
integrations and site PRs are merged and show a green `staging/home-server` tick:

1. `sudo ./staging/install.sh` ends with "integrations reaches the order database (migration 1)".
2. `curl -s http://home-server:8088/api/status` shows `"database":{"reachable":true,"migration":1,"latest":1}`.
3. `sudo /opt/picklemypaddle/staging/backup.sh` writes a dump and a photo archive; then do the
   **restore drill** above ("Restore by hand", scratch database) and paste the output on SCRUM-64.
4. From your phone over Tailscale, place a test order with a camera photo: you get a
   `PMP-` reference, the TEST wording and a private status link that opens. Comment on SCRUM-68.
5. Check the stored photo has no location (SCRUM-66): copy it out and run `exiftool` on it:
   ```bash
   cd /opt/picklemypaddle/staging
   # The latest order that isn't a smoke test (the updater's smoke run places one after every site
   # deploy, so "newest photo" is often its 1600x1200 test image). `</dev/null` stops docker from
   # waiting on the terminal when piped; exiftool's "-" reads stdin, so no copy is left behind.
   sudo docker exec pmp-staging-postgres-1 psql -U pmp -d pmp -tA -F' ' -c "select o.reference, o.created_at, ph.side, ph.path from photos ph join paddles p on p.id = ph.paddle_id join orders o on o.id = p.order_id where not o.is_smoke order by o.created_at desc, ph.side limit 2" </dev/null |
   while read -r ref d t side path; do
     echo "== $ref $d $t $side"
     sudo docker exec pmp-staging-integrations-1 cat "/data/photos/$path" </dev/null | exiftool - | grep -E "Image Size|GPS|Make|Model|Date/Time Original" || echo "   no GPS, Make, Model or date taken"
   done
   ```
   It should name your order's reference, show about 2560x1920 for a phone camera photo, and no
   GPS, Make, Model or date-taken lines. Paste on SCRUM-66.
   (`exiftool` is in Ubuntu's `libimage-exiftool-perl` package.)

## Acceptance checks (SCRUM-34)

1. **CI (site):** the content schema and language folders are unit-tested; Playwright checks
   `/blog`, `/blog/<slug>` and `/rss.xml`, and that `/keystatic` is a 404; the container test
   proves the public image has no `/keystatic` and no Keystatic code, and that the editor image
   starts and sends sign-in back to the Tailscale address.
2. **CI (infra):** the editor runs in the staging stack behind the gateway, on the loopback
   listener only, and the LAN listener 404s its paths; the updater test deploys a stand-in
   editor under its own status name; `--tailscale` adds and removes :8444 without touching
   anything else; `production/` has no editor.
3. **On home-server:** `install.sh` ends with "the LAN address doesn't serve the blog editor";
   `--set-editor-app` ends with "sends sign-in to GitHub with this app"; `tailscale serve
   status` shows `:8443` and `:8444`, no Funnel, the 443 app unchanged.
4. **From the phone, over Tailscale:** write a test post, open a PR from the editor, merge it,
   and see it on staging with a green `staging/home-server` ✓.
5. **Private:** with Tailscale off, `…:8444` doesn't connect; on the LAN,
   `http://home-server:8088/keystatic` is 404.

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
