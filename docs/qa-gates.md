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
| Order form and submit | integrations `orders`, `rules`, `photos`, `abuse`; site `order`, `order-rules-parity` | site `order-form` | `order-smoke` (real 1-paddle order) | the parity test compares with integrations `main` |
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
| **Clubs and batches (SCRUM-85, SCRUM-10)** | **none yet** | **none yet** | **none yet** | SCRUM-85 is not built; its tests are listed in the story |
| Agents (parked) | agents `agents` | n/a | n/a | |

## Non-functional areas

| Area | What guards it | Where | Gaps |
| --- | --- | --- | --- |
| Security headers and CSP (no third-party origins, no inline scripts) | site e2e `headers` (headers set; no CSP violations on pages) | CI, smoke | a new page is covered only if a spec visits it |
| Accessibility | axe in site `site` and `discount-code` specs; Lighthouse accessibility 100 (`lighthouse-budget.json`) | CI | axe runs on a few pages only: extend to every page template |
| Performance | Lighthouse budget (`check:lighthouse`, `tests/unit/lighthouse-budget`) | CI | no load test for integrations (low volume; revisit before club batches) |
| Secrets | gitleaks (`secrets / Secret scan`); `check:secrets` on the built site; dummy keys built at runtime | CI | |
| Container images | Trivy scan (HIGH and CRITICAL), container tests | CI (image job) | site `.trivyignore` expires 9 Nov 2026 |
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
