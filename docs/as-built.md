# As built: where everything lives

Jira: SCRUM-44 (first slice, written 20 Oct 2026). This records what exists today, so
PickleMyPaddle can be rebuilt from nothing. Run-sheets and the disaster recovery plan come in
later slices. Written from the SCRUM-19 status comments (14 and 15 Oct), the staging runbook and
the repos; **`[To confirm: …]` marks facts only Attila has** (fill them in when you review).

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
| Order emails | Resend (Tokyo region) | Domain verified; no API key yet |
| Staging | `home-server` on the home LAN | Live ([runbook](../runbooks/staging-home-server.md)) |
| Code, CI, images | GitHub `thehunfromoz/*`, GHCR | Live |
| Tickets | Jira `thehunfromoz.atlassian.net`, project SCRUM | Live |
| CRM and payments | HubSpot (test portal), Stripe (test mode) | Staging only, not wired up yet |

## OVH

- **Account:** a business login. [To confirm: account type chosen at sign-up, and where the login is kept]
- **Domain:** `picklemypaddle.com`, registered at OVH (by 14 Oct 2026). Nameservers were moved to
  Cloudflare (by 15 Oct), so OVH stays the registrar only. DNSSEC was off at the move.
  [To confirm: registration end date and auto-renew setting]
- **Server:** one VPS-1 in Australia, Sydney (2 vCores, 4 GB RAM, 40 GB NVMe), Ubuntu 26.04, 12-month
  term from 14 Oct 2026. OVH's standard automated backup is included and was confirmed to be stored
  on-shore. [To confirm: backup frequency and retention; term end date and auto-renew]
- **Why a VPS in Sydney:** Australian customers, and the privacy policy can say data is stored in
  Australia. It is not Public Cloud (hourly instances, dearer for the same size), web hosting
  (shared PHP, cannot run our Docker images) or a dedicated server (A$200+/month). The location is
  fixed once bought; moving means a new VPS and a data transfer.
- **Full datacentre, not a Local Zone:** Docker and Compose were installed and tested on it (15 Oct
  status), which a Local Zone can't do: OVH lists Local Zones as Linux-only with no Docker.
- **Traffic:** Asia-Pacific VPS plans have a monthly quota (500 GB on VPS-1, then 10 Mbps), far more
  than this site needs.
- **SSH key at install:** [To confirm: how the key was attached when the VPS was ordered]

## The VPS (hardening)

Done by hand (SCRUM-19 status of 15 Oct); the rebuild run-sheet (later slice) will turn this into steps.

- User `ubuntu`, SSH by key only. An sshd drop-in `00-hardening.conf` turns off password logins and
  root login.
- Firewall (ufw): 22 limited (rate-limited), 80 and 443/tcp open, 443/udp open (HTTP/3).
- **Docker can bypass ufw** for any port a container publishes. The production compose file
  publishes only 80, 443/tcp and 443/udp, which are the open ones.
- Automatic security updates (unattended-upgrades) on.
- Docker and Compose installed from Ubuntu's packages.
- Docker commands use `sudo`. [To confirm: is `ubuntu` in the `docker` group? PR #15 recommends not]

## Cloudflare

- **Account:** on the separate business address, with 2FA via a mobile authenticator app.
  [To confirm: where the 2FA recovery codes are kept]
- **Zone:** `picklemypaddle.com`, Free plan.
- **Records:** `A` for `@` and `www` pointing at the VPS, **DNS only** (not proxied, so Caddy can
  answer its own certificate challenge). No `AAAA` yet: add one once IPv6 is confirmed on the VPS.
  Email Routing adds its `MX` and `SPF` records. Resend's `DKIM`/`SPF` records (and a `DMARC`
  record) go on its sending subdomain. OVH's default records were deleted after the switch.
  [To confirm: whether a DMARC record exists and its policy; the AI-crawler settings chosen in Cloudflare]

## Email

- **Receiving:** Cloudflare Email Routing. `sales@picklemypaddle.com` forwards to the business Gmail
  mailbox (tested); catch-all is off. Not iCloud (personal-use terms, tied to a personal Apple
  Account).
- **Sending:** Resend, for the automatic order emails. The domain is verified on a sending
  subdomain, region Tokyo, click and open tracking off. **No API key exists yet** (15 Oct). When the
  integrations service needs one, it goes only in the VPS's root-only secrets file (see below).
  [To confirm: the sending subdomain name and the From address]
- The privacy policy's email wording was updated in site PR #30.

## Production stack

Compose stack with a Caddy gateway doing automatic HTTPS for `picklemypaddle.com` and `www`,
serving the site only (integrations follow). **No auto-updater:** releases (`vX.Y.Z` tags) are
deployed by hand with `update.sh`, which checks the live site and rolls back on failure. In PR #15
(SCRUM-19); once merged, setup, release, rollback and day-to-day steps are in
[runbooks/production-ovh-vps.md](../runbooks/production-ovh-vps.md). No release is deployed yet.

## Staging

`home-server` on the home LAN (Ubuntu): Compose stack with a Caddy gateway, a pull-based updater
that deploys new `:staging` images, runs the smoke tests and posts a `staging/home-server` commit
status to GitHub. Also reachable on the tailnet over HTTPS for demos. Everything is in
[runbooks/staging-home-server.md](../runbooks/staging-home-server.md).

## Code, CI and images (GitHub)

- Four repos under `thehunfromoz`: `picklemypaddle-site`, `picklemypaddle-integrations`,
  `picklemypaddle-agents`, `picklemypaddle-infra`. All public.
- **Rulesets** on every repo require a PR and passing checks; only Attila merges to `main`.
  Required check names are listed in `docs/working-with-claude.md` (renaming a CI job changes its
  check name, so rulesets need updating).
- **Images:** merge to `main` publishes `ghcr.io/thehunfromoz/<repo>:staging` and `:<commit>`; a
  `vX.Y.Z` GitHub Release re-tags the same image without rebuilding. The GHCR packages for the site,
  its smoke tests and the integrations service are public. The only release so far is `v0.1.0`, a
  "staging test" prerelease from 8 Oct.
- **Shared workflows** live in this repo (`.github/workflows/`) and the other repos call them
  `@main`.
- The session that builds things cannot create tags or releases, change repo settings or rulesets,
  or delete branches; those are Attila's (`docs/working-with-claude.md`).

## Other accounts

- **HubSpot:** a test portal ("PickleMyPaddle test") for now; the live portal comes later. The
  service key is made under Settings → Integrations → Service Keys with contacts, companies and
  deals read/write plus their schema scopes (new HubSpot accounts have no legacy private apps).
  [To confirm: whether the live portal exists yet]
- **Stripe:** test mode only on staging; the integrations service refuses a live key there.
  [To confirm: state of the live Stripe account]
- **Jira:** `thehunfromoz.atlassian.net`, project SCRUM (epics: platform, website, orders,
  payments, clubs, launch, agents, security and privacy).
- **Umami** (self-hosted analytics, chosen for the site): [To confirm: deployed yet, and where]

## Secrets: where each one lives

Names only; never the values.

| Secret | Where | Notes |
| --- | --- | --- |
| GitHub commit-status token | `/etc/picklemypaddle/github-status.token` on home-server (root, 600) | Fine-grained, 1 year, commit statuses on the site and integrations repos only |
| Integrations keys, staging | `/etc/picklemypaddle/integrations.env` on home-server (root, 600) | `STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET`, `HUBSPOT_ACCESS_TOKEN`, `HUBSPOT_PORTAL_ID`; test values only |
| Integrations keys, production | `/etc/picklemypaddle/integrations.env` on the VPS (root, 600) | Not created yet; live keys only, plus the Resend key |
| VPS SSH key | [To confirm: where the private key and its passphrase are kept] | |
| Cloudflare 2FA recovery codes | [To confirm] | |
| Account logins (OVH, Cloudflare, Google, GitHub, Atlassian, HubSpot, Stripe, Resend) | [To confirm: password manager and who can open it] | |

## Dates to calendar

| When | What |
| --- | --- |
| 26 Oct 2026 | Site `.trivyignore` expires: remove it once a fixed Caddy base image is out, or re-review |
| One week after production's first HTTPS | Raise HSTS from one day to one year ([runbook](../runbooks/production-ovh-vps.md)) |
| Monthly | Re-run production `install.sh` to pick up Caddy updates |
| End of Nov 2026 | ABN, then register `picklemypaddle.com.au` and redirect it |
| Oct 2027 | VPS 12-month term ends. [To confirm: exact date, auto-renew] |
| [To confirm] | `picklemypaddle.com` registration end date; GitHub status token expiry (1 year from creation) |

## Not yet written (later slices of SCRUM-44)

The six run-sheets (rebuild the VPS, deploy and roll back, move DNS, rotate secrets, renew, restore
from backup), the disaster recovery plan (scenarios, detection, contacts, ordered recovery steps and
target times), the backup plan with a dated restore test, and an end-to-end rebuild against a
throwaway server.
