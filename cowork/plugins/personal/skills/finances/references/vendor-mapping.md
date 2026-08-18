# /finances → Expand the merchant → category map

A working session to grow `gold.vendor_category_map`, the **known
classifications** table. This is the first thing the classification system
consults; the regex rules exist only for merchants it has never seen.

Goal is 80/20, not completeness: ~200 merchants covers ~78% of transactions,
and the remaining 1,300 are one-and-done merchants that rules and the review
queue should absorb. **Stop at diminishing returns**, don't grind the tail.

**Run this in Claude Code, against the repo.** It writes to the warehouse, and
the door is read-only by design, so from a Cowork seat you can review the
candidate list but not apply anything. Locally it uses `./scripts/query.sh` and
`./scripts/add-vendor-category.sh` directly.

## Why Copilot is the suggestion source

Steven reviewed the Copilot categories by hand historically, so a Copilot
majority for a merchant is the strongest evidence available — better than
Tiller's category, which comes from an unmanaged algorithm the repo
deliberately does not trust. Where Copilot never saw a merchant, the query
falls back to whatever it currently resolves to and says so.

**But Copilot is a strong default, not an oracle.** Measured on the first 250
candidates: 52 disagreed with the current category, and several Copilot answers
were plainly wrong — Experian (a credit bureau) as Restaurants & Bars, a Toast
restaurant POS charge as Car. A suggestion backed by one or two votes is weak
evidence; one backed by dozens is strong. **Read `suggestion_basis` before
accepting**, and treat a low vote count on a surprising category as a prompt to
look rather than a verdict.

## Run the session

```bash
./scripts/query.sh queries/vendor-category-candidates.sql > .context/vendor-candidates.txt
```

Expense merchants whose category was **not deliberately chosen**, ranked by
spend. The population is defined by `classification_source` — `tiller`,
`copilot:reviewed`, `uncategorized`. Anything decided by an override, a mapping
or a rule is deliberate and does not appear.

| Column | Meaning |
|---|---|
| `source` | which unreviewed source is speaking. Two values means the merchant is split across both |
| `running_pct_of_unreviewed_spend` | share of unreviewed spend cleared through this row — **the progress bar** |
| `suggested_category_id` | what to write |
| `suggestion_basis` | `copilot xN` (N transactions voted) or `current (no copilot evidence)` |
| `disagrees` | **true = Copilot and the current category conflict.** These need a human |
| `suggested_action` | what kind of decision this row wants — see the vocabulary below |

Ranked by **spend, not count**. The volume head is done: mappings cover ~81% of
expense transactions. What is left is ~840 merchants averaging 1.2 transactions
each, so ranking by count marches through hundreds of one-time restaurants while
five-figure items wait.

## The action vocabulary

`suggested_action` sorts each row into one of six decisions. They are not
interchangeable, and the difference between the first four and the last two is
what keeps this from doing damage.

| Action | What it means | Tool |
|---|---|---|
| `ALIAS to "X"` | descriptor variant of a merchant already decided. Collapse it and it inherits that decision — **do not write a second mapping** | `scripts/add-vendor-alias.sh` |
| `promote to vendor_map` | Copilot already holds a hand-reviewed category and the merchant recurs. Copy it in so it survives the export and its cutoff date | `scripts/add-vendor-category.sh` |
| `map (recurring merchant)` | recurs, no deliberate decision yet. Usually confirming what Tiller guessed rather than correcting it | `scripts/add-vendor-category.sh` |
| `SUSPECT — verify before trusting` | Tiller said Clothes & Grooming or Unclassified. **Highest error density in the queue** | look, then map or rule |
| `review this transaction (one-off, large)` | will not recur but carries real money. Read it; a per-transaction override if wrong | `scripts/add-override.sh` |
| `accept or catch by rule (one-off, small)` | **stop here.** Accepting a rough guess on a $12 transaction that will never recur costs nothing | nothing, or a pattern rule |

**Why `Clothes & Grooming` and `Unclassified` are called out:** they are Tiller's
dumping grounds for things it cannot place. Kindle Unlimited was filed as
clothing. A category that is merely *wrong* is worse than one that is *missing*,
because nothing flags it.

**Never map a one-off.** A mapping applies confidently to every future
transaction and nothing reviews it again, so a wrong one is worse than none.
Mixed-basket merchants (Amazon, Target) and peer payments stay unmapped by
design — see the judgment calls below.

**Prefer a rule to fifty mappings.** The tail is ~840 merchants at ~1.2
transactions each; they will never be worth naming individually. A pattern rule
(`scripts/add-rule.sh`) that catches a whole shape of description is the only
thing that scales here.

## Watch one number

```bash
./scripts/query.sh queries/classification-sources.sql
```

The share of **expense spend** still classified by `tiller`. It was 20.2% on
2026-08-17. That is the metric this review exists to drive down; transaction
counts flatter the picture because much of the Tiller residual is investment and
transfer plumbing that `flow_type` already excludes from spending.

Removing Tiller from the chain entirely is the end state, but not until that
number is small: measured 2026-08-17, dropping it would have stranded 966
transactions and $87,646 of real spend as Unclassified.

## Work it in batches of ~20

For each batch, present a compact table: rank, merchant, txns, spend,
suggestion, basis, and a clear mark on every `disagrees` row. Then:

- **Agreed rows** (`disagrees` false, Copilot-backed): propose accepting as a
  block. Do not make Steven confirm forty obvious groceries one at a time.
- **Disagreements**: one line each, both candidate categories, and a
  recommendation with its reason. These are the actual work.
- **`current (no copilot evidence)`**: flag as lower-confidence. A merchant
  Copilot never saw is often a recent one, so the current category came from
  Tiller — exactly the source we are replacing. Ask rather than assume.

Write the batch to a TSV and apply it:

```bash
cat > .context/batch.tsv <<'EOF'
Giant Heirloom	groceries	grocery
CVS	healthcare	pharmacy, not grocery
EOF
./scripts/add-vendor-category.sh --batch .context/batch.tsv
```

The whole file is validated before any row is written — a half-applied batch is
worse than a rejected one, because you cannot tell where it stopped.

Re-run the candidates query between batches; mapped merchants drop out and the
coverage percentage advances.

## Rulings Steven has already made

**Apply these without asking again.** Decided 2026-08-17.

| Thing | Category |
|---|---|
| Gas, parking, tolls, car washes (Sunoco, ParkMobile, Exxon, Impark, tollways) | `car` |
| Wawa — his exception to the above | `restaurants_bars` |
| Drugstores and convenience (CVS, Walgreens, 7-Eleven) | `groceries` |
| Hudson News and airport newsstands | `groceries` |
| Bank, billing, ATM and interest fees | `fees` — but an ATM **withdrawal** is `cash` |
| Sitters | `babysitters`, which is distinct from `school` and `childcare` |
| Everyday household goods | `home`; real projects are `home_repair` |
| Amazon | `home`. He accepts it cannot be disentangled — do not re-raise it |
| Bare-"Venmo" bank debits | `internal_transfer`. The itemized Venmo feed carries the real spend, so counting both double-counts |
| Experian | `media` |
| **Movie theatres and movie tickets** (AMC, Cinemark, Fandango) | `recreation`, **not** `media` |
| **Museums, zoos, playgrounds, kids venues** (Please Touch, Franklin Institute, Philadelphia Zoo, Smith Playground, Urban Air) | `kids_recreation` |
| **Sports venues and sporting goods** (Subaru Park, Chestnut Hill Sports) | `recreation` |
| **Betting and gambling** (FanDuel, sportsbooks) | `recreation` |
| **Liquor stores** (Fine Wine & Good Spirits, state stores) | `groceries` |
| Lowe's, Home Depot, hardware stores | `home` — see the everyday/projects split above |

**A ruling applies backwards, not just forwards.** When Steven makes one, re-check
what is already in the map and fix it. The movie-theatre ruling on 2026-08-17
invalidated four rows written earlier that same session (AMC ×2, Cinemark,
Fandango ×2); leaving them would have meant the map disagreed with itself.

**Mixed-basket big-box goes to `home`.** Amazon, Walmart, Apple Store, Target.
Steven's position (2026-08-17) is that they cannot be disentangled and `home` is
the least-wrong bucket, so map them and stop re-raising it. This REPLACES the
earlier "leave mixed baskets unmapped" guidance — unmapped meant they fell
through to Tiller, which filed Apple Store and Walmart under Clothes & Grooming.
A deliberate least-wrong answer beats an accidental wrong one.

## Judgment calls that still need him

- **Anything that is sometimes a business expense** — the household/business
  split is a `work_expenses` question, and it may deserve a rule with an
  account filter rather than a blanket merchant mapping.
- **A `SUSPECT` row where the right answer is not obvious** — say what you found
  and stop, rather than guessing into a permanent mapping.
- **A merchant whose descriptor does not identify it.** Look at the raw
  `full_description`, the amount pattern and the account first — `TST*`/`SQ *`
  prefixes mean a restaurant POS, a repeating identical amount means a
  subscription. If it still will not resolve, ASK. "FSA" ran twice at exactly
  $140 and turned out to be healthcare; no amount of inference would have got
  there.

## Where Copilot sits now

Copilot is a **suggestion source for this review** and a bounded classifier, not
an authority. `vendor_category_map` always wins. Copilot's categories are used
only for transactions inside the hand-reviewed window (on or before the cutoff in
`sql/gold.sql`), because Steven no longer reviews them — anything newer is just
another unreviewed guess. Raise that cutoff only after an actual review.

It is also demonstrably not an oracle: it filed Experian, a credit bureau, under
Restaurants & Bars, and a Toast restaurant POS charge under Car. Read
`suggestion_basis` — `copilot x220` is strong, `copilot x1` is a coin flip.

When a merchant genuinely has no single right answer, **do not map it**. Leave
it for a rule with an amount or account condition, or for per-transaction
overrides. A wrong mapping is worse than no mapping: it is confidently applied
to every future transaction and nothing flags it.

## Finishing

Mappings take effect on the next rebuild of `gold.transactions` — the hourly
job, or `./scripts/deploy.sh` immediately.

Verify the reclassification did what you expected before moving on:

```bash
./scripts/query.sh .context/_verify.sql
```

Row count and `sum_spend` must not move. Only the category distribution should.
If a total changed, a mapping hit a flow it should not have.
