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

Unmapped expense merchants, ranked by transaction count, with:

| Column | Meaning |
|---|---|
| `running_coverage_pct` | share of all expense transactions covered through this row — **the progress bar** |
| `suggested_category_id` | what to write |
| `suggestion_basis` | `copilot xN` (N transactions voted) or `current (no copilot evidence)` |
| `disagrees` | **true = Copilot and the current category conflict.** These need a human |

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

## Judgment calls that recur

These come up repeatedly and are Steven's to make, not the model's:

- **Gas stations** (Sunoco, Wawa) — Copilot says `car`, current says
  `transportation`. Is fuel a car cost or a transport cost? Pick once, apply
  consistently.
- **Drugstores** (CVS) — Copilot says `groceries`, current says `healthcare`.
  Real baskets are usually mixed.
- **Big-box and marketplace** (Amazon, Target) — genuinely mixed baskets. A
  single mapping is a compromise; consider leaving them to rules plus
  per-transaction overrides instead.
- **Anything that is sometimes a business expense** — the household/business
  split is a `work_expenses` question, and it may deserve a rule with an
  account filter rather than a blanket merchant mapping.

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
