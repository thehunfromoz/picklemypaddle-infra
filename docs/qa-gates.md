# QA gates: which tests guard what

SCRUM-92, first pass 4 Nov 2026. Every functional and non-functional area has a row here naming
the tests that guard it and where they run. A story's Definition of Done includes updating its
row: **every acceptance criterion gets a regression test**, and each new test is seen failing
once (break the code or the expectation, watch it go red, put it back) so we know it can fail.

Where they run:

- **CI**: every PR and every push to `main`. These are required checks, so nothing merges red.
  Site: `lint check test:unit test:e2e check:lighthouse check:secrets check:links`, then the image
  build, container test and Trivy scan. Integrations: `typecheck test build test:e2e`, then the
  image and container test (QEMU `-cpu Penryn`, real Postgres 18).
- **Staging smoke**: home-server runs each site build's own smoke image through the gateway after
  every deploy (`EXPECT_STAGING=1`) and rolls back on failure. That's the `staging/home-server` status.
- **Infra CI**: `.github/workflows/ci.yml` in this repo: shellcheck, compose and Caddyfile rules,
  updater, production deploy and rollback, backup, Tailscale and Claude-access tests.

## Functional areas

| Area | Unit / integration | E2e (Playwright) | Staging smoke | Notes and gaps |
| --- | --- | --- | --- | --- |
| Website pages, blog, SEO | site `tests/unit/blog-content`, `visibility`, `testimonials`, `legal` | site `site`, `content-pages`, `blog`, `seo`, `legal-pages`, `mobile-menu` | yes (site smoke suite) | |
| Order form and submit (three required tick-boxes: consent, sanctioned competitions, and that the black grit hides logos and artwork, SCRUM-104) | integrations `orders`, `rules`, `photos`, `abuse`; site `order`, `order-rules-parity` | site `order-form`, `site` (box states), `content-pages` (FAQ), `legal-pages` (terms), `club-lead` (Clubs page notice) | `order-smoke` (real 1-paddle order) | the parity test compares with integrations `main`; orders made before SCRUM-104 have no `artwork_ack_at`; the wording is for Attila's approval on staging; the turnaround is Attila's per-order number set at Accept (default 10, one setting, SCRUM-105): integrations `transitions` and `documents` (as emailed), `admin` (the form), the site's `order-rules-parity` compares its copy's number with the service; orders accepted before it use the default |
| Status page and links | integrations `status` | site `order-status` | partial | |
| Order admin and transitions | integrations `admin`, `transitions`, `queue`, `auto` | integrations `e2e/admin` | no (tailnet only) | |
| Emails (outbox) | integrations `email` (snapshots), `jobs` | n/a | no | allow-list prevents real sends outside production |
| Pricing, postage, GST | integrations `pricing`; site `pricing` | via order and payment specs | no | July table update is a calendar item |
| Discount codes | integrations `discounts`; site `discount` | site `discount-code` | no | |
| Payments (Stripe test) | integrations `payments`, `unpaid`; site `payment` | site `payment`, integrations admin e2e (fake Stripe) | no | the webhook is production only, tested with signed fake events |
| Receipts, invoices, credit notes | integrations `documents`; site `document` | site `document` | no | |
| HubSpot mirror | integrations `crm` (fake HubSpot) | n/a | no | |
| Retention and erasure | integrations `retention`, `erasure` | n/a | no | the staging walk-through is by hand (`backdate-order`) |
| Reviews and testimonials | integrations `reviews`, `review-reminder` | n/a | no | |
| NSW holidays, business days | integrations `holidays` (12-month coverage) | n/a | n/a | |
| Clubs and batches, club invoices and payments, clubs in HubSpot (SCRUM-85), club leads and the pipeline (SCRUM-93), the club agreement (SCRUM-94) | integrations `clubs` (all-or-nothing return and invoice, GST on top; outside production a club's billing email must be allow-listed or a test domain), `club-payments` (PayID and cash in full only, short and over amounts refused, card through fake Stripe, late and wrong payments flagged and alerted, refunds alerted, overdue), `club-crm` (company, contact and a deal per batch in fake HubSpot with its Collected on date, priced with GST once registered; contact change unlinks the old one; recovery; order syncs unaffected by missing club stages; a retry that finds a newer job pending), `club-leads` (the form's validation and API: honeypot, minimum fill time, per-address and per-email limits, no member or street-address data, a repeat club alerts without a second record; one lead, one acknowledgement and one alert; the pipeline moves and the billing check; a lead in HubSpot, a shared contact kept, a public name never overwriting one; 12-month retention), `club-agreements` (version selection, the production placeholder guard, a sent version never edited, send with the full text and the club moving to Agreement sent, the printable page, recording the reply, the gate for pickups); site `document`, `club-lead`, `agreement` | site `club-invoice` (invoice, payments received with no balance line, Pay by card, 409, `/club/paid` incl. a payment needing review), `club-lead` (the Clubs page form: CSP, axe, posted fields, errors, closed service), `club-agreement` (the printable agreement: token in the body only, text not markup, invalid links); integrations admin e2e (a lead's pipeline with its meeting time, send the agreement and record the reply); `club-postage` (a batch received by post: method, one tracking number each way, refused on a pickup, admin wording and the 6-paddle postage note), `club-leads` (meeting time and length, shown in HubSpot's "Club meeting"), `club-agreements` (v0.2: dead-spot check, postage section, cross-references); site e2e (Clubs page and FAQ offer pickup or post; the service-area map with its alt text and suburb list; the form's venue postcode and its inside/outside note, which never blocks sending); `service-area` unit tests in both repos (matching rules, real examples) and a parity test, in integrations, that its copy equals the site's (the site owns the list and map) on `main`; `club-postage` also covers payment before return (invoice, pay, then return; return refused until paid) and the postage allowance line (the club's postage to us, standard cost from the venue postcode, entered when it can't be worked out, GST on the net, none under 6 paddles); `club-leads` (default method, version recorded, wrong postcode flagged, override recorded and reversible, HubSpot "Club pickup or post") | no (admin and tailnet only) | "overdue" no longer fires (an invoice is due before return and has no due date); `CLUB_PAYMENT_TERMS_DAYS` and the overdue check are kept on purpose and FLAGGED FOR REVIEW AFTER GOING TO PRODUCTION (clubs may insist on deferred payment); the launch area is the smaller 35-minute list (the wide original is kept, unused), the GST treatment of the postage allowance is unchecked with an accountant; returning a batch emails the club (`club_returned`: date, and the tracking number for a posted one; tests in `club-postage`), and the admin venue form says when an override still wins over the new default; a refunded club card payment alerts Attila and shows on the batch page (`club-payments`), but what it does to the balance and whether a credit note is issued is not built (decision pending); no ledger yet (SCRUM-86); agreement v0.5 (0.1 never sent, 0.2 and 0.3 sent only to staging test clubs and frozen: a test pins 0.3's hash; 0.4 added artwork, 0.5 the usual 10-business-day turnaround and Attila's right to change it per batch) is an unapproved draft with `[To confirm: …]` items, so production sends none and the first real send needs Attila's approval and a resolved text (production enforces both); an agreement email's link isn't checked against a real mail client, and the "I agree" reply path is untested end to end (Gmail hides mail sent from the same account; test from a second mailbox). Clubs' later stories (SCRUM-95 to 97) have no tests yet |
| Agents (parked) | agents `agents` | n/a | n/a | |

## Non-functional areas

| Area | What guards it | Where | Gaps |
| --- | --- | --- | --- |
| Security headers and CSP (no third-party origins, no inline scripts) | site e2e `headers` (headers set; no CSP violations on pages) | CI, smoke | a new page is covered only if a spec visits it |
| Accessibility | axe in site `site` and `discount-code` specs; Lighthouse accessibility 100 (`lighthouse-budget.json`) | CI | axe runs on a few pages only: extend to every page template |
| Performance | Lighthouse budget (`check:lighthouse`, `tests/unit/lighthouse-budget`) | CI | no load test for integrations (low volume; revisit before club batches) |
| Secrets | gitleaks (`secrets / Secret scan`); `check:secrets` on the built site; dummy keys built at runtime | CI | |
| Container images | Trivy scan (HIGH and CRITICAL), container tests | CI (image job) | site `.trivyignore` expires 16 Nov 2026 |
| Old CPU on home-server (pre x86-64-v2) | integrations container test under QEMU `-cpu Penryn` | CI | the site image isn't run under Penryn (static Caddy, low risk) |
| Staging and production stacks | compose and Caddyfile rules, loopback-only listeners, internal networks, orders off in production | infra CI `lint`, `site-image` | |
| Deploy, rollback, recovery | updater tests; production `update.sh` tests | infra CI `updater` | |
| Backups | backup writes, restores into scratch and prunes | infra CI `updater` | no off-site copy or dated restore test yet (SCRUM-44) |
| Privacy (no street address or photos in HubSpot; status page minimal) | integrations `crm`, `status`, `logs` (no personal data in logs) | CI | |
| Abuse limits | integrations `abuse` (honeypot, timing, per-IP and per-email limits) | CI | |
| Placeholders never shown | `check:placeholders` (blocks releases); production refuses `[To confirm: …]` templates | release, production start | |
| Claude Code's access to home-server | infra `tests/claude-access.test.sh` (incl. the address `on` offers when `sudo` hides `SSH_CLIENT`, and `install.sh --claude-access <key-file> <address>`; the key's `from=` is exactly one IPv4/IPv6 address, SCRUM-100) | infra CI `lint` | Part 2 (real user and sudo, interactive `on`) runs only in CI; access over the tailnet is checked by hand with `ssh pmp-staging status` |

## How a story uses this

1. During refinement, name the rows the story touches and the tests it will add (in Jira).
2. Before merging, the review agent checks that every acceptance criterion maps to a test, and that
   the new tests ran in CI (look at the counts, not just the tick).
3. Update this file in the same PR when a row changes: a new area, a new test file, a gap closed.
