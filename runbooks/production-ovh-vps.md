# Production on the OVH VPS: setup and day-to-day

Jira: SCRUM-19. Production is **https://www.picklemypaddle.com** (the bare domain
`picklemypaddle.com` redirects to it), served from the OVH VPS-1 in Sydney. Today it runs the
website only; the integrations service (orders, CRM, payments) joins later. The same gateway can
serve other websites on this server (see "Adding another website").

## How it works

```
GitHub (merge to main) ─► CI ─► GHCR :staging ─► home-server: tests and your sign-off
                                     │
      you publish a release vX.Y.Z on GitHub ─► CI re-tags that image :vX.Y.Z (no rebuild)
                                     │
      on the VPS: sudo update.sh deploy vX.Y.Z ─► pull, health check, live-site checks,
                                                  roll back by itself if anything fails

visitors ─► :80 / :443 ─► gateway (Caddy, automatic HTTPS) ─► site
```

- **Nothing deploys itself.** There is no timer. You run `update.sh deploy vX.Y.Z` by hand; it
  shows what changes (with a GitHub compare link) and asks before it does anything.
- **Release tags only.** Production never runs `:staging` or a commit tag, only `vX.Y.Z`
  images that CI built from `main` and staging already ran.
- **The gateway stays up** while the site is updated, rolled back or not deployed yet. Visitors
  then see a plain "temporarily unavailable" page (HTTP 503, not indexed) instead of a connection
  error, and the certificates are never lost.
- **`www` is the canonical address** (the site's canonical links and sitemap use it); the bare
  domain answers with a permanent redirect to it. Caddy gets a certificate for both.
- **Certificates** are kept in the Docker volume `pmp-production-caddy-data`. Don't delete it:
  Let's Encrypt limits how often one name can be issued a certificate.
- Container logs are capped (3 × 10 MB per container), so they can't fill the 40 GB disk.
- **The gateway can serve several websites.** Its main `gateway/Caddyfile` holds only the shared
  settings; each website is one file in `gateway/sites/` (Pickle My Paddle is
  `picklemypaddle.caddy`). Each website runs in its own Compose project on its own private
  network, and the gateway joins that network, so websites can't reach each other, only the
  gateway reaches them. They share the gateway, the certificates volume and the server, so a
  gateway mistake or a server compromise affects all of them (CI validates the gateway config).
- Pickle My Paddle runs in its own Compose project (`pmp-production`) and network. Only the gateway
  publishes ports (80, 443/tcp, 443/udp for HTTP/3). The firewall (ufw) already allows these;
  remember Docker can bypass ufw for any port it publishes, so the compose file publishes nothing else.
- Use `sudo` for Docker commands. Don't add the `ubuntu` user to the `docker` group: that
  group is root-equivalent, and the `sudo` password prompt is a useful pause.

## One-time setup

Already done (SCRUM-19 status of 15 Oct): the VPS is hardened (SSH keys only, root login off,
ufw, automatic security updates, Docker and Compose installed), `picklemypaddle.com` is on
Cloudflare with `A` records for `@` and `www` pointing at the VPS (**DNS only**, not proxied, so
Caddy can answer the certificate challenge).

### 1. Install the stack

```bash
ssh ubuntu@<the VPS address>
git clone https://github.com/thehunfromoz/picklemypaddle-infra.git ~/picklemypaddle-infra
cd ~/picklemypaddle-infra
sudo ./production/install.sh --check    # pre-flight only: Docker, ports 80/443 free, DNS points here
sudo ./production/install.sh            # installs to /opt/picklemypaddle/production, starts the gateway
```

The installer copies the files to `/opt/picklemypaddle/production` (the checkout in your home
folder is only a source to review and install from), starts **only the gateway**, and waits until
`https://www.picklemypaddle.com` and `https://picklemypaddle.com` both answer with a valid
certificate. It ends with "no site release is deployed yet": that is correct at this point.

### 2. Check it from your Mac

```bash
curl -sI https://www.picklemypaddle.com/gateway-healthz | head -1     # HTTP/2 200
curl -sI https://picklemypaddle.com/ | grep -i '^location'            # https://www.picklemypaddle.com/
curl -sI http://www.picklemypaddle.com/ | head -3                     # 308, Location: https://…
curl -s https://www.picklemypaddle.com/                               # the "temporarily unavailable" page
```

The last one is expected until the first release is deployed.

## Before the first release (launch checklist)

The first `vX.Y.Z` that goes to production is the launch. Check these first:

- [ ] **No placeholders left** in the site: `pnpm build && pnpm check:placeholders` passes. Open
      items: the terms page (return postage service, lost/damaged remedy), the About photo and the
      ABN in the site data. Nothing blocks a release automatically yet: the check isn't wired into CI.
- [ ] **The site image doesn't point at staging.** A release only re-tags the image CI built on
      `main`, and that image used to be built with `SITE_URL=http://home-server:8088`, so the
      canonical links, the sitemap and `robots.txt` would name `home-server`. The site repo's PR #31
      builds it with the production address instead. **Cut the first release from a commit that
      includes that change**; `update.sh` refuses (and rolls back) a release that still names
      `home-server` (the "staging address" check).
- [ ] **Signed off on staging:** the commit you release is the one staging runs
      (`http://home-server:8088/version.txt`), with a green `staging/home-server` tick.
- [ ] Privacy policy shows the right contact email and the OVH Sydney location.
- [ ] ABN registered (decision: before launch).

## Deploying a release

1. **Publish the release** on GitHub: `picklemypaddle-site` → **Releases** → **Draft a new
   release** → **Choose a tag** → type `vX.Y.Z` → **Create new tag on publish** → Target `main`
   (or the exact commit staging runs) → **Publish release**. The `Release` workflow then points
   `:vX.Y.Z` at the image CI already built for that commit (it fails for a commit that never went
   through `main`). Wait for it to go green on the repo's Actions tab.
2. **Deploy it** on the VPS:
   ```bash
   sudo /opt/picklemypaddle/production/update.sh deploy vX.Y.Z
   ```
   It pulls the image, shows `running` vs the new release and the compare link, and asks
   `Deploy vX.Y.Z to https://www.picklemypaddle.com ? [y/N]`. Open the compare link first.
3. **What it checks** after starting the new release, through the real gateway and certificate:
   it becomes healthy; `/version.txt` is that release's commit; the home page has HSTS and a
   Content-Security-Policy and does **not** say noindex; no page, `robots.txt` or sitemap mentions
   `home-server`; `robots.txt` doesn't block the site; `/env.css` doesn't reveal the staging-only
   elements.
4. **If a check fails**, the previous release is put back automatically (on the very first
   deploy the site is stopped and visitors get the 503 page), the reason is printed and logged in
   `/var/lib/pmp-production/site.failed`, and `.env` is left unchanged. Only a passing deploy is
   recorded.

`--yes` skips the question (`update.sh deploy vX.Y.Z --yes`) for when you have already reviewed it.

### Roll back by hand

```bash
sudo /opt/picklemypaddle/production/update.sh rollback
```

This redeploys the release that ran before the last successful deploy (through the same checks).
`update.sh status` names it as the "rollback target".

## Day to day

| I want to… | Run on the VPS |
| --- | --- |
| See what's running and recent deploys | `sudo /opt/picklemypaddle/production/update.sh status` |
| Re-run the live-site checks | `sudo /opt/picklemypaddle/production/update.sh check` |
| See what's running (Docker) | `sudo docker compose -p pmp-production ps` |
| Read the gateway log (certificates, requests) | `sudo docker compose -p pmp-production logs --tail 50 gateway` |
| Read the site log | `sudo docker compose -p pmp-production logs --tail 50 site` |
| Deploy history | `sudo cat /var/lib/pmp-production/site.deployed` |
| Failed deploys | `sudo cat /var/lib/pmp-production/site.failed` |

### Apply changes from this repo (and refresh Caddy)

Changes to the compose file, gateway or updater are never picked up automatically. Re-running
the installer also pulls the latest Caddy image, so do it every month or so even without changes:

```bash
cd ~/picklemypaddle-infra && git pull
git log -p ORIG_HEAD..HEAD -- production/    # review what changed
sudo ./production/install.sh
```

It restarts the gateway only when its Caddyfile, a website's file in `gateway/sites/`, or its
settings changed (a few seconds without HTTPS),
never changes the site's release, and applies a changed `.env` setting to the running site.
`sudo ./production/install.sh --check` warns "installed files differ from this checkout" when you
have pulled but not installed yet.

### Adding another website

For a second site on this server (the consulting site, say). Nothing here changes Pickle My
Paddle's site or its certificates. The gateway restarts for a few seconds when it is applied.
Do the DNS step first, because Caddy can only get a certificate once the name points here.

1. **DNS (Cloudflare):** `A` records for the new names (`@` and `www`) pointing at the VPS,
   **DNS only** (not proxied), as for Pickle My Paddle.
2. **The site's own stack** gets its own Compose project (a separate folder such as
   `/opt/picklemypaddle/<name>`, its own `.env`, its own release process; it never shares files
   or secrets with Pickle My Paddle). Its web container must have a **unique network alias**
   (for example `blog-site`) and join a network that the gateway also joins:
   ```yaml
   services:
     site:
       networks:
         blogweb:
           aliases: [blog-site]
   networks:
     blogweb:
       name: blog-web
       external: true     # created by the gateway's compose file (next step)
   ```
3. **In this repo (a PR, as usual):** in `production/compose.production.yml` add the network
   (`blogweb: {name: blog-web}`) at the bottom and to the gateway's `networks:` list. Copy
   `production/gateway/sites/new-site.caddy.example` to `production/gateway/sites/<name>.caddy`
   and put in the real domain and alias. CI validates the result.
4. **Install:** `sudo ./production/install.sh` (it copies the new file and recreates the gateway),
   then start the new site's own stack. Until it runs visitors get the plain 503 page.
5. **Check it yourself** (the installer proves HTTPS for Pickle My Paddle only):
   `curl -sI https://www.<new-domain>/ | head -n 1` and `curl -sI https://<new-domain>/ | head -n 1`
   (expect a `200`, and a `301` to `www`).

To take a website away: delete its file in `gateway/sites/` (and its network from the compose
file) in a PR, then run `install.sh`; it removes the installed file and restarts the gateway.

Keep this to static or light websites: the VPS-1 has 2 vCores and 4 GB RAM. Anything heavy or
holding customer data (a mobile-app backend with accounts, say) is better on a second server.

### Raise HSTS after a week

`HSTS` starts at one day (`max-age=86400`) so a mistake can be undone. After a week of clean
HTTPS:

```bash
sudo nano /opt/picklemypaddle/production/.env     # HSTS="max-age=31536000; includeSubDomains"
cd ~/picklemypaddle-infra && sudo ./production/install.sh
```

Keep the quotes. `includeSubDomains` covers every subdomain you ever add (analytics, a CMS),
so only use it once those are served over HTTPS too.

## If something's wrong

| Symptom | Fix |
| --- | --- |
| `install.sh` waits, then "no valid certificate for …" | The `A` record for that name doesn't point at this server, or Cloudflare has it proxied (it must say **DNS only**), or port 80/443 is blocked (ufw, an OVH firewall). Fix it and re-run. The reason is in `sudo docker compose -p pmp-production logs --tail 50 gateway`. Let's Encrypt allows only a few failed attempts per hour: wait before retrying a lot. |
| Browser shows "temporarily unavailable" | The site isn't running (not deployed yet, a failed first deploy, or restarting). `update.sh status`; deploy a release or roll back. |
| `deploy` says "cannot pull" | The release doesn't exist (typo, or the `Release` workflow failed or is still running), or the GHCR package `picklemypaddle-site` isn't public. |
| `deploy` fails with "the staging address (home-server)" | The image was built with the staging `SITE_URL`. See the launch checklist above. |
| `deploy` fails with "noindex" or "Disallow: /" | A staging setting reached production: the gateway on this server must be the production one (`install.sh`), and the image must be a release. |
| Disk filling up | `sudo docker image prune` removes images nothing uses (older releases are pulled again if a rollback needs them). Container logs are already capped. |

## Remove production

```bash
sudo docker compose -p pmp-production down     # stops both containers; keeps the certificates
sudo rm -r /opt/picklemypaddle/production /var/lib/pmp-production
# Only if you also want to throw the certificates away:
sudo docker volume rm pmp-production-caddy-data
```

## Acceptance checks (SCRUM-19)

1. **CI (infra):** the `Lint scripts and compose file` job shellchecks `production/*.sh`, validates
   the production compose file and runs `caddy validate` on the gateway Caddyfile with every
   website file in `gateway/sites/` (and the new-site template), and fails if
   `production/` gains an updater timer or the auto-update label. The `Updater deploys, rolls back
   and recovers` job runs `tests/production-update.test.sh`: install, HTTPS on `localhost`, the
   503 page, a failed first deploy, release-tags-only, a good deploy, an unhealthy release, a
   release with the staging address, a second release, rollback, re-install, and a second
   website added to and removed from the gateway without touching the Pickle My Paddle site.
2. **On the VPS:** `sudo ./production/install.sh` ends with "Done" and the four `curl` checks above
   give the expected answers.
3. **First release:** `update.sh deploy vX.Y.Z` ends with "is live at https://www.picklemypaddle.com",
   and `https://www.picklemypaddle.com/version.txt` shows the release's commit.
