---
doc: household
owner: Steven
last-reviewed: 2026-08-16
update-when: an income source starts or ends; the household composition or a
  major recurring obligation changes; the tax situation changes
---

# Household — framing for the advisor branch

Durable framing facts, so an advisor answer reasons about the right unit.

**What may live in a context doc:** structure, and the occasional *aggregate
magnitude* where the number is the whole point of a blind spot ("~$38k/year of
mortgage outflow is invisible" is actionable; "some outflow is invisible" is
not). **What may never:** transactions, merchant names, account numbers, or
current balances. Those come from a query at read time. These files ship inside
a plugin, so treat every line as published to Steven's claude.ai account.

## The unit of analysis

**Household and business are one unit.** Steven left a W-2 role on 2026-03-15 and
now splits time between half-time work at Bobsled and Plum Growth, his own
consultancy. Business revenue and household spending land in overlapping
accounts, so:

- A household-only view **understates income** (it misses business revenue).
- A business-only view **understates obligations** (it misses the household).

Model both together, then say which side any given number came from.

## Who is in it

Steven and Hannah, with two children — Bruce (6) and Ada (4). Childcare and
schooling are a material, seasonal line rather than a fixed one, and the mirror
has historically **understated it**: recurring aftercare has not appeared as a
recognizable vendor, and evening babysitting shows up under individual names
rather than a category. Treat any childcare figure derived purely from the data
as a floor, and say so.

## Income has three shapes, and they are not interchangeable

1. **Employment income** — regular, already net of withholding and deferrals.
2. **Self-employment income** — irregular, and **gross**. Never call it
   spendable without a 35–40% tax reserve; state the rate used.
3. **Off-mirror income** — never crosses a bank feed, lives in
   `finance.manual_income`, and must be added to every income answer. See
   `definitions.md` for why it is additive rather than a double-count.

For any source, report **months paid out of months in range**. A source paying 4
of 12 months is not a salary, and averaging it as one produces a forecast that
cannot happen.

## Standing obligations that shape every forecast

- **Taxes are the largest unreserved liability.** Self-employment income carries
  no withholding, and quarterly estimates have been missed before. Any runway
  figure that ignores a tax reserve is wrong by the size of the reserve. The
  Philadelphia BIRT/NPT treatment is a CPA question, not one to answer from data.
- **The mortgage is not fully observable.** Its funding account is not linked to
  Tiller (see `accounts.md`), so it must be assumed rather than measured.
- **Lumpy annual commitments** — insurance, subscriptions, tuition-shaped items —
  belong in the amortized tier of the monthly nut, never in the fixed tier.

## Tone

Steven wants the number and the thing he should do about it, in that order. He is
fluent in the business and the data and not in implementation detail — explain
mechanisms plainly, define terms inline, lead with the answer.

Give ranges rather than false precision, and name the assumption that moves the
answer most. When something is unknowable from the data, say that plainly instead
of estimating around it — the blind spots in `accounts.md` are part of every
honest answer.
