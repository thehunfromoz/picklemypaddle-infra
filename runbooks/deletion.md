# Deleting customer data: on request, and the monthly sweep (SCRUM-75)

The integrations service deletes order data by itself (daily retention job) and on request (admin
→ Retention → Erase a customer). This runbook covers what the service can't reach: the business
Gmail mailbox, Resend's email log, and (once SCRUM-9 is built) Stripe. It also covers backups.

Retention rules, in short (the privacy policy, "How long we keep it"):

| What | Kept | Deleted by |
| --- | --- | --- |
| Paddle photos | 12 months after Completed | the service, daily |
| Orders that never went ahead (Rejected, Withdrawn, Lapsed, never paid) | 12 months after that status | the service, daily |
| Paid orders (tax record) | 5 years after Completed (or Withdrawn after paying) | the service, daily |
| Order mail in Gmail | 12 months | you, monthly sweep (below) |
| Resend's copy of sent emails | 30 days | Resend, by itself |
| Backups of the order database and photos | 30 days | the backup job, nightly |

## When a customer asks us to delete their data

Reply within 30 days (the privacy policy promises it). Work through these in order and tick
them off in your reply draft.

### 1. The service (orders, photos, HubSpot)

1. Open the admin: staging `https://home-server.tail8bc7ae.ts.net:8445/admin/retention`, production
   `https://pmp-prod.tail8bc7ae.ts.net/admin/retention`. Choose **Erase a customer's data on request**.
2. Enter the email address the customer ordered with. If they used more than one, do each.
3. Read the preview:
   - **Still open:** an order is between Submitted and Posted back. Finish it (post the paddle
     back and complete it) or withdraw it first, then come back. Erasing now would lose the
     return address.
   - **Deleted entirely:** orders they never paid for.
   - **Kept as a tax record only:** paid orders inside their 5 years. Only the reference, name,
     dates, statuses and amount stay; the daily job deletes them when the 5 years are up.
4. Tick the box and **Erase now**. The result page gives the counts. HubSpot is updated first
   (contact GDPR-deleted, deals deleted or stripped); if HubSpot can't be reached nothing is
   erased, so just try again later.
5. The Retention page's **Erasures** list now shows the erasure (counts and categories only).
   That is your evidence it was done.

### 2. Gmail (the business mailbox)

Mail to `sales@`, `info@` and `attila@` arrives in the business Gmail mailbox.

1. Sign in to the business Gmail account (login in Apple Passwords).
2. Search: `from:<their address> OR to:<their address>`. Also search their order references
   (`PMP-XXXXX`, from the erasure preview) and their name, because Attila's new-order alerts
   and review alerts mention the reference, not the address.
3. Select all results → **Delete**. Then open **Trash**, select the same messages →
   **Delete forever**. (Gmail otherwise keeps Trash for 30 days.)
4. If you replied from another account or forwarded anything, delete it there too.

### 3. Resend (sent order emails)

Resend keeps each sent email (content, metadata, delivery events) for **30 days**, then deletes it
by itself, on every plan (checked 30 Oct 2026: [Resend's quotas and limits](https://resend.com/docs/knowledge-base/account-quotas-and-limits)).
Nothing to do unless the customer wants it gone sooner: then in the Resend dashboard, **Emails**,
search their address, and contact Resend support to ask for deletion of those messages.

### 4. Stripe (once payments are built, SCRUM-9)

[To be completed with SCRUM-9.] Stripe keeps payment records it is legally required to keep.
Customer objects we create can be deleted in the Stripe dashboard (Customers → the customer →
Delete), which doesn't remove the payment records themselves.

### 5. Backups

Nothing to do. Erased data stays in the nightly backups (`/var/backups/picklemypaddle/<stack>`)
for at most 30 days, until they're pruned. The privacy policy says so. Any off-site copy
(SCRUM-44) must keep no more than 30 days either.

### 6. Reply to the customer

Tell them what was deleted, and that for any paid order a minimal tax record (reference, name,
dates, amount) is kept until 5 years after the order, then deleted. Mention that copies in
backups are gone within 30 days.

## Every month: the Gmail sweep

The service's own data follows the rules by itself; Gmail doesn't. On the first business day of
each month:

1. In the business Gmail, search: `older_than:12m`.
2. Keep anything that's still needed (an open dispute, supplier or ABN paperwork, or an order
   held back with an extension: check the admin's Retention page, "Extensions in force").
3. Delete the rest, then empty those messages from **Trash** (**Delete forever**).

## Checking the daily job

- Admin → Retention: "Due for deletion in the next 14 days" (by rule), "Recent runs" (counts).
- On the host, what's due now, without deleting anything:
  ```bash
  cd /opt/picklemypaddle/staging   # production: /opt/picklemypaddle/production, with -f compose.production.yml
  sudo docker compose -f compose.staging.yml exec integrations node dist/cli/retention-run.js --dry-run
  ```
- **To keep an order longer** (a dispute, say): open it in the admin, **Keep it longer**, a date
  and a reason. Every rule waits until after that date.
- **"waiting on HubSpot"** in a run means due orders were kept because HubSpot couldn't be
  reached; they're tried again the next day. If it persists, check the HubSpot key.

## Trying it on staging (no real data)

1. Place a TEST order, reject it in the admin (any reason).
2. Back-date it 13 months (test only; refused in production and for non-TEST orders):
   ```bash
   cd /opt/picklemypaddle/staging
   sudo docker compose -f compose.staging.yml exec integrations node dist/cli/backdate-order.js PMP-XXXXX 13
   sudo docker compose -f compose.staging.yml exec integrations node dist/cli/retention-run.js --dry-run   # lists it under "enquiries"
   sudo docker compose -f compose.staging.yml exec integrations node dist/cli/retention-run.js
   ```
3. The order is gone from the admin and its deal and contact from the HubSpot test portal; its
   status link says the link isn't valid.
4. For erasure: place another TEST order with your own address, walk it to Completed, then erase
   that address from the Retention page and check the order now shows "Erased on request".
