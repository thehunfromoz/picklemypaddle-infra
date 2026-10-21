# Google Search Console: go-live checklist

Jira: SCRUM-36 (the checklist), SCRUM-11 (launch). Do this once, on the day the first release goes live
on **https://www.picklemypaddle.com** (see `production-ovh-vps.md`), and again for any new domain.

What the site already does (SCRUM-36, in the site repo): every page has its own title and description,
a canonical link on `https://www.picklemypaddle.com`, `/sitemap.xml` listing exactly those canonical
URLs, `/robots.txt` allowing everything and pointing at the sitemap, share-preview tags, and JSON-LD
(Organization and Service on the home page, FAQPage on `/faq`). Staging is kept out of search by the
staging gateway (`X-Robots-Tag: noindex, nofollow` and a disallow-all `robots.txt`); the image itself
never says noindex, which is why production is indexable without any change.

No verification token, login or account address goes in this repo (it is public). The token lives
only in Cloudflare DNS and in your Search Console account.

## Before you submit anything

Run these from any machine once the release is live. Each should print what the comment says.

```bash
curl -sI https://www.picklemypaddle.com/ | head -n 1                         # HTTP/2 200
curl -sI https://www.picklemypaddle.com/ | grep -i x-robots-tag              # (nothing: no noindex)
curl -s  https://www.picklemypaddle.com/robots.txt                           # Allow: / and Sitemap: …/sitemap.xml
curl -s  https://www.picklemypaddle.com/sitemap.xml | grep -c '<loc>'        # one per page (8 today)
curl -sI https://picklemypaddle.com/ | grep -i '^location'                   # https://www.picklemypaddle.com/
curl -s  https://www.picklemypaddle.com/ | grep -o '<link rel="canonical"[^>]*>'   # www, with the slash
```

If `robots.txt` says `Disallow: /` or a response carries `noindex`, stop: the staging gateway or a
hand-edited file is answering for production. Fix that first; submitting a noindex site wastes weeks.

## Set up Search Console

1. Open Google Search Console and add a **Domain** property for `picklemypaddle.com`. A Domain
   property covers `www`, the bare domain, http and https together, so the redirect does not split
   your data.
2. Google shows a `TXT` record. In Cloudflare (DNS) add it at the root name `@`. DNS is already
   "DNS only", and a TXT record is never proxied. Wait a minute, then click **Verify**.
   Leave the record in place permanently: removing it un-verifies the property.
3. **Sitemaps** → add `sitemap.xml` (the full address is `https://www.picklemypaddle.com/sitemap.xml`).
   Status should become **Success** with 8 discovered pages (more as the blog grows). "Couldn't
   fetch" on the first try is common for a few minutes; check again before changing anything.
4. **URL inspection** → paste `https://www.picklemypaddle.com/` → **Test live URL**. Expect
   "URL is available to Google" and "Indexing allowed: Yes", and the user-declared canonical equal to
   the Google-selected one. Then **Request indexing**. Repeat for `/faq`, `/clubs` and `/about`.
5. **Enhancements** (appears after the first crawl, which can take days): the home page should show
   Organization and the service listing without errors; `/faq` shows FAQ. Google limits FAQ rich results to
   some kinds of sites, so the FAQ may be valid but show no rich result. That is expected, not a fault.
6. Optional: add your own Google account as an owner under **Settings → Users and permissions** so
   the property survives a lost login.

## After launch

- **Week 1:** Pages → "Why pages aren't indexed". "Discovered, currently not indexed" on a new site is
  normal; "Blocked by robots.txt" or "Excluded by noindex" is not (see the warning above).
- **Each new page or blog post:** it appears in the sitemap on the next release. No action needed,
  but URL inspection → Request indexing speeds the first crawl.
- **Changing the domain** (the `.com.au` plan in `as-built.md`): add it as its own property, set
  `SITE_URL` in the site build, redeploy, and use Change of Address from the old property.
  The `www` host stays the canonical one.

## If something looks wrong

| Symptom | Likely cause |
| --- | --- |
| Sitemap "Couldn't fetch" for more than a day | `curl` the address above from outside; a 503 means the site container is down (the gateway answers "temporarily unavailable" with `noindex`). |
| "Page with redirect" for the bare domain | Expected: it redirects to `www`. Only worry if `www` itself redirects. |
| Google picks a different canonical | The page was reachable at a second address (an old `.com.au`, a `:8088` staging link). Check `curl -s <address> \| grep canonical`. |
| Staging pages appear in search | Staging gateway not installed or stale: `git pull && sudo ./staging/install.sh` on home-server, then `curl -sI http://home-server:8088/ \| grep -i x-robots-tag`. |
