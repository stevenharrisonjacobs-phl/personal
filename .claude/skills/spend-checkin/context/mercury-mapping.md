# Mercury counterparty → venture mapping

owner: Steven · last-reviewed: 2026-09-08 (seeded from 90 days of live history)
update-when: an `unmapped` counterparty appears in a morning report, or a new
vendor starts billing the Plum Growth account.

Maps Mercury (Plum Growth LLC) counterparties for the Other subscriptions
section. Matching is case-insensitive substring against `counterpartyName`.
No match → `unmapped`, listed for review — never guessed. No amounts in this
file; it is committed to git.

## Counting rules (learned from the live account shape)

- Spend = `creditCardTransaction` rows (they live on the separate Mercury
  Credit account) plus genuine checking outflows. The monthly `IO AUTOPAY`
  pair (counterparties `Mercury Credit` / `Mercury Checking ••…`) is the
  card settlement moving money between Steven's own accounts — counting it
  alongside the card charges double-counts every subscription. Exclude it.
- Inflows are not subscriptions: `Mercury IO Cashback` (rewards) and the
  Bobsled payroll wire (`Bobsled` / `C101782 BOBSLED`) are income — exclude
  from the spend total, but the payroll arriving (or missing) is worth one
  Notes line.
- Window on `postedAt` (`status: sent`); pending card authorizations have no
  posted date yet — note their count, never their amounts.

## Venture map

| Counterparty contains | Venture | Status |
|---|---|---|
| anthropic | snapfix | observed monthly (API credits + Claude sub) |
| openai | snapfix | observed monthly (API + ChatGPT sub) |
| apify | snapfix | observed monthly ("Apify* Inv#…") |
| langsmith | snapfix | anticipatory — no charge in last 90d |
| langchain | snapfix | anticipatory |
| google cloud | snapfix | anticipatory |
| lusha | snapfix | anticipatory |
| vantage | snapfix | anticipatory |
| webflow | bobsled | anticipatory |
| hubspot | bobsled | anticipatory |

## Ignore (internal / inflow — excluded from spend per counting rules)

| Counterparty contains | Why |
|---|---|
| mercury credit | card autopay settlement (internal) |
| mercury checking | card autopay settlement (internal) |
| mercury savings | internal transfer |
| mercury io cashback | rewards inflow |
| bobsled | payroll inflow (note its presence, don't count as spend) |

## Known-unmapped (observed in the last 90 days — Steven to assign)

lovable · conductor · vercel · notion · slack · granola · railway ·
jump desktop · sessionwatcher.com · era finance

Say "map <vendor> to snapfix/bobsled" during any check-in and the mapping
gets a row.
