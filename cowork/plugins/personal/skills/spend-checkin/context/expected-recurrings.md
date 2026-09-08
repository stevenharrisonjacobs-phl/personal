# Expected recurring charges — curated

owner: Steven · last-reviewed: 2026-09-08 · update-when: a recurring charge is
added/cancelled, or a watch item in the morning report is wrong twice.

Curated expectations merged ON TOP of `queries/recurring-watchlist.sql` (the
history-derived floor). Use this file for charges history can't infer well:
annual/quarterly cadence, seasonal resumptions, or things that matter enough to
name explicitly. Vendor names match `gold.transactions.vendor_name`
(case-insensitive substring). No amounts in this file; it is committed to git.

| Vendor contains | Cadence | Expected | Note |
|---|---|---|---|
| mortgage | monthly | by the 5th | the quarter-of-missed-payments incident — never drop this row |
| martial posture | annual | ~August | resumed Aug last year; nothing yet this year (open item kyiv-dbm) |

> Seed status: minimal. Add rows as morning reports surface gaps — the
> history-derived query already covers ordinary monthly subscriptions.
