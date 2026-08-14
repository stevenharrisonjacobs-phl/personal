---
name: inbound
description: "What's physically coming to the house — packages, online orders in transit, and today's letter mail from USPS Informed Delivery — read across all Gmail mailboxes and filtered down to what's real, not spam. Use when Steven invokes /inbound or asks 'what packages are coming', 'what's arriving', 'anything in the mail today', 'what did I order', 'track my deliveries'."
---

# /inbound

Answer one question: **what physical mail and packages are coming to the house,
and when.** Pull from all mailboxes, kill the marketing noise, and hand back a
short arrival board sorted by when things land.

All email access is local + read-only via `scripts/gmail.py` (4 mailboxes, merges
all accounts). You never send, reply, or click anything in email. The USPS letter
step drives the browser read-only.

Two engines run independently — if one fails, still deliver the other:
- **Packages & Orders** — from email. Always works.
- **Letters** — from USPS Informed Delivery. Needs the browser + a logged-in
  USPS session; degrades gracefully when unavailable.

Default (`/inbound`) runs both. `/inbound packages` = engine 1 only.
`/inbound mail` or `/inbound letters` = engine 2 only.

## Step 0 — Anchor & context

```bash
date "+%A %Y-%m-%d %H:%M"
```

Skim `docs/people-and-workstreams.md` for household names — Steven, **Hannah**
(also Kasperzak / Kinship Company), **Bruce**, **Ada**, and extended family. A
letter or package addressed to any of them is relevant; "resident"/"current
occupant" mail is junk. Note the primary account is `stevenharrisonjacobs@gmail.com`
(where USPS Informed Delivery lands) — but shipping mail arrives across all four.

---

## Engine 1 — Packages & Orders (email)

### 1a. Gather (run all searches in parallel via Bash, `--json`)

Cast wide; you'll filter hard in synthesis. Use ~14 days by default (a package
ordered two weeks ago may still be in transit); the user can widen.

```bash
cd <gmail-mailbox-access workspace>   # any checkout with .venv + .secrets; see note below
scripts/gmail.py search 'subject:(shipped OR "out for delivery" OR "on its way" OR "arriving" OR "has shipped")' --days 14 --json --limit 60
scripts/gmail.py search 'subject:("order confirmation" OR "your order" OR "order #" OR "we received your order" OR "thanks for your order")' --days 14 --json --limit 60
scripts/gmail.py search '"tracking number" OR "track your package" OR "track my order" OR "your package"' --days 14 --json --limit 60
scripts/gmail.py search 'from:(ups.com OR fedex.com OR usps.com OR shipment-tracking@amazon.com OR auto-confirm@amazon.com OR order-update@amazon.com OR narvar.com OR shopifyemail.com OR shop.app)' --days 14 --json --limit 60
```

Notes:
- A `warning: skipping <account>` on stderr = stale token; keep going, add a
  one-line footer telling the user to run `scripts/google_auth.py add`.
- IDs repeat across searches — dedupe by message `id` before reading.
- For any item where the subject alone doesn't tell you item/date/status, pull the
  body: `scripts/gmail.py read <id> --account <acct> --json`. Don't read every
  message — only the ambiguous ones. Carrier "out for delivery" mails and Amazon
  "arriving today" mails usually need no body read.

### 1b. Extract & dedupe

For each real order/shipment build one record:
`{ merchant, item (best guess), carrier, tracking (if present), expected_date, status }`

`status` ∈ `ordered` (not shipped yet) · `shipped / in transit` · `out for
delivery / arriving today` · `delivered` (drop delivered unless it landed today).

**Dedupe the lifecycle.** One purchase generates order-confirmation → shipped →
out-for-delivery emails, sometimes across two senders (merchant + carrier). Merge
them into a single row keyed on merchant+item or tracking number, keeping the
**latest** status and the tightest delivery date. Never list the same package
three times.

**Amazon specifics (it's usually the bulk of the feed):**
- **Match by order number**, not item text. Every Amazon email carries the order
  ID `\d{3}-\d{7}-\d{7}` in its body — group the Ordered→Shipped→Delivered chain
  by that ID and take the latest event per order. The item-count subjects ("1
  Apparel item", "3 Lawn & Garden… items") are unreliable for matching — the same
  order shows different counts across notices.
- **A shipped item with a past ETA and no "Delivered" notice = treat as arrived.**
  Amazon doesn't always send (or we don't always capture) the delivery ping. Only
  call something still-coming if its ETA is today/future or it's not yet shipped.
- **Item names are often withheld.** Amazon anonymizes many items to a generic
  category ("1 Apparel item", "1 Drugstore item") for privacy — and the real name
  is NOT in the email body either (verified: body has only order #, order total,
  ETA, and a login-gated "view order" link). Don't try to recover the name from
  email; say the category, and note the **order total** (also in every email) as a
  disambiguator. The only source for the true name/status is the Amazon "Your
  Orders" page — offer the browser-confirmation pass (below) when it matters.
- To read Amazon emails wide: `from:(auto-confirm@amazon.com OR
  shipment-tracking@amazon.com OR order-update@amazon.com OR ship-confirm@amazon.com)`.

**Kill the noise** — these match the keywords but are NOT inbound physical goods:
- Newsletters / Substacks / beehiiv / marketing blasts ("your order" in a promo)
- Digital receipts with nothing shipping (SaaS, subscriptions, app renewals)
- HubSpot / CRM / sales-tool notifications, calendar invites, review requests
- "Your order has been delivered" from >1 day ago (already arrived)
- Food delivery / rideshare receipts (not mail)
When unsure whether something physical is actually coming, prefer to include it
with a `(?)` rather than silently drop it.

---

## Engine 2 — Letters (USPS Informed Delivery)

**Reality:** the USPS digest email is only a "your digest is ready to view"
notice — the grayscale mail-piece scans are **not** in the email (confirmed: the
HTML holds only USPS logos + a tracking pixel). The scans live behind login at
`informeddelivery.usps.com`. So reading letters requires the browser.

### 2a. Confirm there's a digest today

```bash
scripts/gmail.py from "USPSInformeddelivery@email.informeddelivery.usps.com" --days 2 --json --limit 3
```

No digest in the last ~1 day → USPS has nothing scanned (Sundays/holidays, or no
scannable mail). Say so and skip to output. A digest exists → proceed.

### 2b. Read the mail-piece scans via the browser

Load the Claude-in-Chrome tools in ONE ToolSearch call:
`select:mcp__claude-in-chrome__tabs_context_mcp,mcp__claude-in-chrome__tabs_create_mcp,mcp__claude-in-chrome__navigate,mcp__claude-in-chrome__computer,mcp__claude-in-chrome__read_page`

Then:
1. `tabs_context_mcp` first (session hygiene — never reuse old tab IDs).
2. Create a new tab → navigate to
   `https://informeddelivery.usps.com/box/pages/secure/DashboardAction_input?keyword=mail`
3. **If redirected to a login screen** → USPS session isn't active. Do NOT attempt
   to log in or enter credentials. Fall back (Step 2c) and tell the user to sign in
   at informeddelivery.usps.com, then re-run `/inbound mail`.
4. **If the dashboard loads** → the mail pieces render as grayscale scan images.
   Screenshot the mailpiece section (`computer` screenshot) and read each piece
   with vision. For each: identify **sender** (return-address / logo / company)
   and **type**, then classify:
   - **Relevant** — a real letter to the household: bills & statements, government
     / IRS / court / DMV / USCIS, banks & financial, insurance, medical, legal,
     checks or anything hand-addressed, cards/personal mail to Steven, Hannah,
     Bruce, or Ada, anything time-sensitive or requiring action.
   - **Junk** — advertising / marketing mail, credit-card & insurance solicitations,
     catalogs, coupons/circulars, political mailers, and anything to "Resident" /
     "Current Occupant" / "Our Neighbor".
   Some pieces USPS can't image (it shows a placeholder + "no image available");
   note those as "unimaged mail piece" rather than guessing.

USPS also lists inbound **packages** on this dashboard — ignore them here; Engine 1
already covers packages more reliably from email.

### 2d. Optional — Amazon "Your Orders" confirmation pass

When the email data leaves package status ambiguous (a shipped item with no
delivery notice) or the user wants **real item names** for anonymized orders, and
a logged-in Amazon session exists in Chrome, navigate to
`https://www.amazon.com/gp/css/order-history` (or `?ref_=nav_orders_first`),
filter to open/not-yet-delivered, and read the real names + exact status. Same
guardrail as USPS: if it bounces to a sign-in page, do NOT log in — fall back to
the email-derived board and tell the user to sign in, then re-run. This is the
only reliable source for anonymized Amazon item names.

### 2c. Fallback (browser or login unavailable)

Report from email only: "USPS has a digest for <date> — log in at
informeddelivery.usps.com to view the scans." Don't fabricate senders.

---

## Step 3 — Output

Lead with what's arriving soonest. Keep it a scannable board, not prose.

```
📦 Arriving today / out for delivery
  • <item> — <merchant> via <carrier> · <tracking?>
📬 In transit
  • <item> — <merchant> · est. <date> · via <carrier>
🧾 Ordered, not yet shipped
  • <item> — <merchant> · ordered <date>

✉️ Today's mail (USPS, <date>)  — <N relevant of M pieces>
  • <sender> — <type>              e.g. "Chase — statement", "PA DMV — letter"
  (junk hidden: N marketing pieces)
```

Rules:
- Only show status buckets that have items. No empty headers.
- Under each package, one line: what it is, who it's from, carrier, tightest ETA.
  Tracking numbers only if present and useful.
- For letters, list relevant pieces; collapse junk to a single count. If a piece
  is genuinely ambiguous, show it with `(?)`.
- If an engine failed or degraded, add ONE honest line ("USPS: not logged in —
  couldn't read today's scans") — never invent.
- End with a stale-token footer only if a mailbox was skipped.

## Guardrails
- Read-only everywhere. No sends, no replies, no clicking email links, no entering
  USPS credentials.
- Never fabricate a package, delivery date, or letter sender. Missing/uncertain →
  say so or mark `(?)`.
- gmail.py needs a checkout with `.venv` + `.secrets/` (e.g. `madison`,
  `tiller-bigquery-finance-mirror`, `gmail-mailbox-access`). If the current
  workspace lacks them you'll get "Google client libraries are not installed" —
  run from one that has them.
