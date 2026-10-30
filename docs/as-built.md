# As built: where everything lives

Jira: SCRUM-44 (first slice, written 20 Oct 2026). This records what exists today, so
PickleMyPaddle can be rebuilt from nothing. Run-sheets and the disaster recovery plan come in
later slices. Written from the SCRUM-19 status comments (14 and 15 Oct), the staging runbook and
the repos, then checked with Attila item by item on 20 Oct 2026.

Rules for this file:

- **This repo is public.** No passwords, keys, tokens, recovery codes, IP addresses or account
  login addresses. Say *where* something is kept, never what it is.
- Any infra change updates this file (and the matching runbook) in the same PR.

## At a glance

| What | Where | State |
| --- | --- | --- |
| Domain `picklemypaddle.com` | Registered at OVH; DNS on Cloudflare | Live |
| Production server | OVH VPS-1, Sydney (Ubuntu 26.04) | Running, hardened; stack in PR #15 (SCRUM-19) |
| Production site | `https://www.picklemypaddle.com` | No release deployed yet |
| DNS, email routing | Cloudflare (Free plan) | Live |
| Retention and erasure | The integrations service, daily (SCRUM-75); Gmail and Resend by [runbook](../runbooks/deletion.md) | Built 30 Oct 2026 |
| Order emails | Resend (Tokyo region) | Domain verified; staging key and allow-list on home-server (SCRUM-69); no production key yet |
| Staging | `home-server` on the home LAN | Live ([runbook](../runbooks/staging-home-server.md)) |
| Blog editor (Keystatic) | Staging only, on the tailnet at `:8444/keystatic` | Added by SCRUM-34 ([runbook](../runbooks/staging-home-server.md#blog-editor-over-tailscale-scrum-34)) |
| Code, CI, images | GitHub `thehunfromoz/*`, GHCR | Live |
| Tickets | Jira `thehunfromoz.atlassian.net`, project SCRUM | Live |
| Order database | Postgres 18 per stack, reachable only by integrations | Staging: live with SCRUM-64. Production: defined, off until orders are switched on |
| Order backups | `/var/backups/picklemypaddle/<stack>` on each host, nightly, kept 30 days | Staging: timer installed by `install.sh`. Production: set up when orders open. Off-site copy: SCRUM-44 |
| CRM and payments | HubSpot (test portal), Stripe (test mode) | HubSpot mirror live on staging (SCRUM-74); Stripe not wired up yet |
| Tailnet | Tailscale, tailnet `tail8bc7ae.ts.net`: home-server, the VPS (`pmp-prod`, tagged) and Attila's devices | Live; VPS joined 28 Oct 2026 (SCRUM-71) |
| Order admin | Tailnet only: staging `https://home-server.tail8bc7ae.ts.net:8445/admin`, production `https://pmp-prod.tail8bc7ae.ts.net/admin` | Added by SCRUM-71/72; production answers 503 until orders are on |

## OVH

- **Account:** an **individual** account (the legal form chosen at sign-up), with 2FA on (Google
  Authenticator). The login is kept in Apple Passwords. OVH's renewal and expiry notices go to
  Attila's main email, which he reads daily.
- **Domain:** `picklemypaddle.com`, registered at OVH on 14 Oct 2026 for one year, so it **must be
  renewed before 14 Oct 2027**. Auto-renew is on, but the account has **no payment method stored**,
  so a payment method must be added (or the renewal paid by hand) before then. Nameservers were moved
  to Cloudflare (by 15 Oct), so OVH stays the registrar only. DNSSEC was off at the move.
- **Server:** one VPS-1 in Australia, Sydney (2 vCores, 4 GB RAM, 40 GB NVMe), Ubuntu 26.04, bought
  14 Oct 2026 on a 12-month term, so it also **renews before 14 Oct 2027** (auto-renew on, same
  payment-method point as the domain).
- **Backups:** OVH's standard automated backup is included and was confirmed to be stored
  on-shore. It runs **daily at 08:49 UTC** (about 19:49 in Sydney in summer time); the latest seen
  on 20 Oct was 19 Oct 08:49 UTC. How many copies OVH keeps was not recorded. No restore has been
  tried yet (the dated restore test is part of SCRUM-44), and there is no copy outside OVH yet.
- **Why a VPS in Sydney:** Australian customers, and the privacy policy can say data is stored in
  Australia. It is not Public Cloud (hourly instances, dearer for the same size), web hosting
  (shared PHP, cannot run our Docker images) or a dedicated server (A$200+/month). The location is
  fixed once bought; moving means a new VPS and a data transfer.
- **Full datacentre, not a Local Zone:** Docker and Compose were installed and tested on it (15 Oct
  status), which a Local Zone can't do: OVH lists Local Zones as Linux-only with no Docker.
- **Traffic:** Asia-Pacific VPS plans have a monthly quota (500 GB on VPS-1, then 10 Mbps), far more
  than this site needs.
- **SSH key at install:** one key pair, put on the server with `ssh-copy-id` after the first login
  (it was not added through OVH's SSH key list). The private key exists only on Attila's Mac and is
  protected by a passphrase, which is kept in Apple Passwords.

## The VPS (hardening)

Done by hand (SCRUM-19 status of 15 Oct); the rebuild run-sheet (later slice) will turn this into steps.

- User `ubuntu`, SSH by key only. An sshd drop-in `00-hardening.conf` turns off password logins and
  root login.
- Firewall (ufw): 22 limited (rate-limited), 80 and 443/tcp open, 443/udp open (HTTP/3).
- **Docker can bypass ufw** for any port a container publishes. The production compose file
  publishes only 80, 443/tcp and 443/udp, which are the open ones.
- Automatic security updates (unattended-upgrades) on.
- Docker and Compose installed from Ubuntu's packages.
- Docker commands use `sudo`; `ubuntu` is **not** in the `docker` group (checked 20 Oct, as PR #15
  recommends), because that group is root-equivalent.

## Ports on home-server (decided 29 Oct 2026)

Host ports below 8100 are for Attila's own apps; ours start at 8100, in blocks of ten per app, so
the two never collide (the order admin first took 8090, which wanderer already had). Tailscale
Serve's HTTPS ports (8443–8445) are in Serve's own namespace, not the host's, so they stay as they
are; 8444 is also the blog editor's GitHub App callback. `staging/install.sh` refuses a loopback
port something else holds before changing anything.

| Port | What |
| --- | --- |
| 8088 | PickleMyPaddle staging, LAN (kept: bookmarks, CORS origins, smoke tests) |
| 8090 | wanderer (Attila's) |
| 8100 | PickleMyPaddle staging: order admin, loopback only (`ADMIN_LOCAL_PORT`) |
| 8101 | PickleMyPaddle staging: blog editor, loopback only (`EDITOR_LOCAL_PORT`) |
| 8102–8109 | spare, PickleMyPaddle |
| 8110–8119 | the consulting site, when it arrives |
| Serve 443, 8443, 8444, 8445 | tailnet only: another app (`localhost:3000`), staging, blog editor, order admin |

The VPS uses the same loopback port for its admin listener (127.0.0.1:8100) for consistency.

## Tailscale (SCRUM-38, SCRUM-71)

- **Tailnet:** `tail8bc7ae.ts.net`, MagicDNS and HTTPS certificates on. The login is Attila's;
  the policy is edited in the Tailscale admin console (Access controls).
- **home-server:** an owner device (not tagged). Tailscale Serve answers on `:8443` (staging),
  `:8444` (blog editor) and `:8445` (order admin), set up by `staging/install.sh --tailscale`;
  `:443` belongs to another app and is never touched. Never Funnel.
- **The VPS:** device `pmp-prod`, tag `tag:pmp-prod`, joined 28 Oct 2026 with
  `tailscale up --hostname=pmp-prod --advertise-tags=tag:pmp-prod` (no Tailscale SSH). Tailscale
  1.104.4 at install, from Tailscale's official apt repository (key and list added by hand; the
  `tailscale-archive-keyring` package keeps the key current). **Key expiry: disabled** (tagged
  device default, confirmed in the admin console). Tailscale Serve on the tailnet's `:443` forwards
  to the gateway's loopback-only admin listener (production runbook, "Tailscale and the order admin").
- **Policy (28 Oct 2026):** the default allow-all grant was replaced. `tag:pmp-prod` is owned by
  `autogroup:admin`. Attila's devices reach each other on all ports and `tag:pmp-prod` on TCP 443
  only; nothing has `tag:pmp-prod` as its source, so the VPS can't open connections into the
  tailnet. The `funnel` node attribute is removed. The policy's `tests` block checks: owner
  allowed to home-server 22/443/8443/8444 and pmp-prod 443; owner denied pmp-prod 22/80/5432;
  `tag:pmp-prod` denied to home-server. **When the admin's port 8445 on home-server is added to
  the tests, add it as an owner-allowed port.**
- **ufw on the VPS is unchanged**: nothing is opened for Tailscale.

## Cloudflare

- **Account:** on the separate business address, with 2FA via Google Authenticator on Attila's
  phone (the app's cloud sync to a Google account is on). Recovery codes are kept in Attila's iCloud
  Notes, one note per service.
- **Zone:** `picklemypaddle.com`, Free plan.
- **Records:** `A` for `@` and `www` pointing at the VPS, **DNS only** (not proxied, so Caddy can
  answer its own certificate challenge). No `AAAA` yet: add one once IPv6 is confirmed on the VPS.
  Email Routing adds its `MX` and `SPF` records. Resend's records are two `CNAME`s (`send` and
  `rsend`) and a `TXT` at `resend._domainkey`. OVH's default records were deleted after the switch.
- **DMARC:** a `TXT` record at `_dmarc` with `v=DMARC1; p=none;` (added 20 Oct 2026). Policy `none`
  means monitor only, and there is no reporting address. Tighten to `quarantine` or `reject` later,
  once real order emails have been flowing for a while.
- **AI-crawler settings:** none set in Cloudflare. They would not act on the website anyway while its
  records are DNS only (visitors don't pass through Cloudflare); the site's own `robots.txt` decides.

## Email

- **Receiving:** Cloudflare Email Routing. Three addresses forward to the business Gmail mailbox
  (all tested 20 Oct); catch-all is off. `sales@picklemypaddle.com` takes every sales enquiry and
  order from the website; `info@` is for ordinary dialogue with customers once an order is taken;
  `attila@` is the personal address, for clubs. Not iCloud (personal-use terms, tied to a personal Apple
  Account).
- **Sending:** Resend, for the automatic order emails, which come **From `sales@picklemypaddle.com`**
  with Reply-To `info@`. The domain is verified on the sending subdomain `send.picklemypaddle.com`,
  region Tokyo, click and open tracking off. The `rsend` CNAME is Resend's return-path (bounce)
  domain: mail leaves Amazon SES (Tokyo) with an envelope sender at `rsend.picklemypaddle.com`,
  which is what SPF checks, and DKIM signs as `picklemypaddle.com` (selector `resend`). Staging
  test order of 29 Oct 2026: SPF, DKIM and DMARC all pass (SCRUM-69). Replying to customers *as*
  `sales@`, `info@` or `attila@` (Gmail "Send mail as" through Resend SMTP) is SCRUM-78, before
  launch.
- **API keys (SCRUM-69):** one per environment, "Sending access" on `picklemypaddle.com` only, kept
  only in that host's root-only integrations secrets file. Staging's is named `staging home-server`.
  Production's is made when orders are switched on. A key is shown once at creation; to replace one,
  create a new key, update the file, re-run `install.sh`, then delete the old key in Resend.
- **Retention at Resend:** sent emails (content, metadata, delivery events) are kept **30 days** on
  every plan, then deleted by Resend (checked 30 Oct 2026, Resend's "account quotas and limits"
  page). Gmail is swept monthly by hand ([deletion runbook](../runbooks/deletion.md)).
- **What the service sends:** the customer's emails at key moments (Submitted, Accepted, In queue,
  Posted back, Rejected), the "email me my links" reply, and a reference-only new-order alert to
  `sales@`. Outside production only the allow-listed addresses ever receive mail. Detail: the
  integrations README, "Order emails".
- The privacy policy's email wording was updated in site PR #30.

## Production stack

Compose stack with a Caddy gateway doing automatic HTTPS for `picklemypaddle.com` and `www`,
serving the site only (integrations follow); further websites can be added beside it, one file
each. **No auto-updater:** releases (`vX.Y.Z` tags) are
deployed by hand with `update.sh`, which checks the live site and rolls back on failure. Added in
PR #15 (SCRUM-19); setup, release, rollback, adding another website and day-to-day steps are in
[runbooks/production-ovh-vps.md](../runbooks/production-ovh-vps.md). Attila plans a consulting
and showcase site, and possibly a third, on the same VPS. AdventureLog and its companion mobile app
stay on home-server (reached over Tailscale); a mobile-app backend with user accounts would get its
own server. No release is deployed yet.

## Staging

`home-server` on the home LAN (Ubuntu): Compose stack with a Caddy gateway, a pull-based updater
that deploys new `:staging` images, runs the smoke tests and posts a `staging/home-server` commit
status to GitHub. Also reachable on the tailnet over HTTPS for demos. Everything is in
[runbooks/staging-home-server.md](../runbooks/staging-home-server.md).

**Blog editor (SCRUM-34):** a Keystatic service in the staging stack only, its own image
(`picklemypaddle-site-editor`, from the site repo's `Dockerfile.editor`). The gateway serves it on a
listener published on loopback only, which Tailscale Serve exposes on the tailnet at port 8444; the
LAN address answers 404 for it. Sign-in is through the GitHub App **PickleMyPaddle Blog Editor** on
the thehunfromoz account, installed only on `picklemypaddle-site` with Contents and Pull requests
read/write and no webhook; its callback URL is the editor's tailnet address. Saving creates `blog/…`
branches; posts publish by pull request. Production never runs it.

**Order database (SCRUM-64):** service `postgres` (`postgres:18-alpine`, database and user `pmp`) on
an internal Docker network (`pmp-staging-db`) that only integrations joins; no published port. Data
in the volume `pmp-staging-pgdata`, paddle photos in `pmp-staging-photos` (never served). Nightly
backup at 02:30 Sydney time (`pmp-staging-backup.timer`) to `/var/backups/picklemypaddle/staging`
(root, 700): a `pg_dump` and a photo archive, kept 30 days. Restore and reset steps are in the
[runbook](../runbooks/staging-home-server.md#order-database-scrum-64).

**Order admin (SCRUM-71/72):** integrations serves it on its own port (8081), which the public
gateways never route (`/admin` is 404 on the LAN and public addresses). Each gateway has a third
listener (`:8082`) published on `127.0.0.1:8100` only, which Tailscale Serve exposes on the tailnet;
the gateway reaches the admin over an internal network (`pmp-staging-admin`, `pmp-production-admin`)
that only it and integrations join. Who may sign in is `ADMIN_LOGINS` in each host's root-only
integrations secrets file (staging: `install.sh --set-admin-logins`).

**Orders in production (SCRUM-68):** `integrations` and `postgres` are defined in
`production/compose.production.yml` (volumes `pmp-production-pgdata`, `pmp-production-photos`) but
sit in the `orders` profile, and the gateway answers `/api/*` with 503 while `PMP_ORDERS` isn't
`open`. Switching on is a documented step in the
[production runbook](../runbooks/production-ovh-vps.md#switching-orders-on).

## Code, CI and images (GitHub)

- Four repos under `thehunfromoz`: `picklemypaddle-site`, `picklemypaddle-integrations`,
  `picklemypaddle-agents`, `picklemypaddle-infra`. All public.
- **Rulesets** on every repo require a PR and passing checks; only Attila merges to `main`.
  Required check names are listed in `docs/working-with-claude.md` (renaming a CI job changes its
  check name, so rulesets need updating).
- **Images:** merge to `main` publishes `ghcr.io/thehunfromoz/<repo>:staging` and `:<commit>`; a
  `vX.Y.Z` GitHub Release re-tags the same image without rebuilding. The GHCR packages for the site,
  its smoke tests, the blog editor (`picklemypaddle-site-editor`: staging only, never released) and
  the integrations service are public. The only release so far is `v0.1.0`, a
  "staging test" prerelease from 8 Oct.
- **Shared workflows** live in this repo (`.github/workflows/`) and the other repos call them
  `@main`.
- The session that builds things cannot create tags or releases, change repo settings or rulesets,
  or delete branches; those are Attila's (`docs/working-with-claude.md`).

## Other accounts

- **HubSpot:** only the developer test account "PickleMyPaddle test" (free CRM) exists, and staging
  uses it. A separate real account, free CRM to start, is created near go-live; real customers never
  go in the test account. The service key is made under Settings → Integrations → Service Keys with
  contacts, companies and deals read/write plus their schema scopes (new HubSpot accounts have no
  legacy private apps).
- **Stripe:** no account yet. A test-mode account is created when it is needed; the integrations
  service refuses a live key on staging. Going live is likely gated by the ABN.
- **Jira:** `thehunfromoz.atlassian.net`, project SCRUM (epics: platform, website, orders,
  payments, clubs, launch, agents, security and privacy).
- **Umami** (self-hosted analytics, chosen for the site): **not deployed anywhere** (checked on the
  VPS and home-server, 20 Oct). The site's privacy policy already says the site uses Umami, so before
  launch either deploy it or reword the policy.

## Secrets: where each one lives

Names only; never the values.

| Secret | Where | Notes |
| --- | --- | --- |
| GitHub commit-status token | `/etc/picklemypaddle/github-status.token` on home-server (root, 600) | Fine-grained token "home-server staging status", commit statuses on the site and integrations repos only; **expires 1 Oct 2027** |
| Integrations keys, staging | `/etc/picklemypaddle/integrations.env` on home-server (root, 600) | `DATABASE_URL` (written by `install.sh`), `RESEND_API_KEY` and `EMAIL_ALLOWLIST` (SCRUM-69; the service won't start without the allow-list), `ADMIN_LOGINS` (SCRUM-71; personal, not secret), `STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET`, `HUBSPOT_ACCESS_TOKEN`, `HUBSPOT_PORTAL_ID`; test values only |
| Blog editor, staging | `/etc/picklemypaddle/editor.env` on home-server (root, 600) | `KEYSTATIC_GITHUB_CLIENT_ID` and `KEYSTATIC_GITHUB_CLIENT_SECRET` (set with `install.sh --set-editor-app`; a new secret can be generated on the GitHub App's page), `KEYSTATIC_SECRET` (cookie key, generated by `install.sh`). No production equivalent |
| Order database password, staging | `/etc/picklemypaddle/postgres.env` on home-server (root, 600) | `POSTGRES_PASSWORD`, made once by `install.sh`; the data volume only opens with it. `install.sh` also writes the matching `DATABASE_URL` into the staging integrations file above |
| Integrations keys, production | `/etc/picklemypaddle/integrations.env` on the VPS (root, 600) | Not created yet; live keys only, plus `RESEND_API_KEY` (production refuses to start without it), `DATABASE_URL` and `ADMIN_LOGINS` |
| Tailscale node keys | Inside `tailscaled`'s state on each machine (root) | Nothing to copy or rotate by hand; the VPS's key doesn't expire (tagged) |
| Order database password, production | `/etc/picklemypaddle/postgres.env` on the VPS (root, 600) | Not created yet; made when orders are switched on |
| VPS SSH key | Private key on Attila's Mac only; passphrase in Apple Passwords | Public half is in the VPS's `authorized_keys` |
| 2FA recovery codes (OVH, Cloudflare, Resend, GitHub, Jira) | Attila's iCloud Notes, one note per service | 2FA codes themselves: Google Authenticator, synced to a Google account |
| Account logins (OVH, Cloudflare, Google, GitHub, Atlassian, HubSpot, Stripe, Resend) | Apple Passwords (iCloud Keychain) | Only Attila can open it |

## Dates to calendar

| When | What |
| --- | --- |
| 2 Nov 2026 | Site `.trivyignore` expires: remove it once a fixed Caddy base image is out, or re-review |
| One week after production's first HTTPS | Raise HSTS from one day to one year ([runbook](../runbooks/production-ovh-vps.md)) |
| Monthly | Re-run production `install.sh` to pick up Caddy updates |
| End of Nov 2026 | ABN, then register `picklemypaddle.com.au` and redirect it |
| By 30 Dec 2026, then each December | Add the next year's NSW public holidays to integrations `src/orders/holidays.ts` (from nsw.gov.au); its coverage test fails once the list doesn't reach 12 months ahead (SCRUM-73) |
| 14 Sep 2027 and 1 Oct 2027 | Reminders: add a payment method to OVH (none is stored) or plan to pay by hand |
| 1 Oct 2027 | GitHub status token "home-server staging status" expires: make a new one, update the file on home-server |
| Before 14 Oct 2027 | Renew `picklemypaddle.com` and the VPS at OVH (both bought 14 Oct 2026 for one year) |

## Not yet written (later slices of SCRUM-44)

The six run-sheets (rebuild the VPS, deploy and roll back, move DNS, rotate secrets, renew, restore
from backup; the order database's restore steps are already in the staging runbook), the disaster recovery plan (scenarios, detection, contacts, ordered recovery steps and
target times), the backup plan with a dated restore test, and an end-to-end rebuild against a
throwaway server.
