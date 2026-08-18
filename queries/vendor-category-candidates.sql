-- Expense merchants whose category was NOT deliberately chosen — the review queue
-- for classification. One row per merchant, highest spend first.
--
-- The population is defined by `classification_source`, not by absence from the
-- map: 'tiller' is an unmanaged algorithm, 'copilot:reviewed' is hand-reviewed but
-- bounded by an export and its cutoff date, 'uncategorized' is nothing at all.
-- Rows decided by an override, a mapping or a rule are deliberate and excluded.
--
-- Ordered by SPEND, not transaction count. The volume head is done (mappings now
-- cover ~81% of expense transactions); what remains is ~840 merchants averaging
-- 1.2 transactions each, so ranking by count marches through hundreds of one-time
-- restaurants while five-figure items wait.
WITH expense_vendors AS (
  SELECT
    vendor_name,
    COUNT(*) AS txns,
    ROUND(SUM(spend_amount), 2) AS spend,
    MAX(transaction_date) AS last_seen,
    -- Which unreviewed source is speaking for this merchant.
    STRING_AGG(DISTINCT classification_source ORDER BY classification_source) AS source
  FROM `__PROJECT_ID__.__GOLD_DATASET__.transactions`
  WHERE flow_type = 'expense'
    AND vendor_name IS NOT NULL
    AND NOT STARTS_WITH(vendor_name, 'Unresolved Vendor ')
    AND classification_source IN ('tiller', 'copilot:reviewed', 'uncategorized')
  GROUP BY vendor_name
), mapped AS (
  -- Already-decided merchants, to spot descriptor variants of them. A variant
  -- wants an ALIAS (scripts/add-vendor-alias.sh), not a second mapping — then it
  -- inherits the decision already made.
  SELECT DISTINCT
    vendor_name AS mapped_name,
    LOWER(REGEXP_REPLACE(vendor_name, r'[^a-zA-Z0-9]', '')) AS mapped_key
  FROM `__PROJECT_ID__.__GOLD_DATASET__.vendor_category_map`
  WHERE enabled
), copilot_votes AS (
  SELECT
    t.vendor_name,
    c.category_id,
    c.category_name,
    COUNT(*) AS votes,
    ROW_NUMBER() OVER (PARTITION BY t.vendor_name ORDER BY COUNT(*) DESC, c.category_name) AS rnk
  FROM `__PROJECT_ID__.__GOLD_DATASET__.copilot_transaction_matches` AS m
  JOIN `__PROJECT_ID__.__GOLD_DATASET__.transactions` AS t USING (transaction_key)
  JOIN `__PROJECT_ID__.__GOLD_DATASET__.categories` AS c
    ON c.active AND c.category_id = m.copilot_category_id
  -- 'unclassified' is Copilot declining to answer, not an answer. Writing it
  -- into the map would freeze a non-decision in as if it were reviewed.
  WHERE c.category_id != 'unclassified'
  GROUP BY t.vendor_name, c.category_id, c.category_name
), current_votes AS (
  SELECT
    vendor_name,
    canonical_category,
    COUNT(*) AS votes,
    ROW_NUMBER() OVER (PARTITION BY vendor_name ORDER BY COUNT(*) DESC, canonical_category) AS rnk
  FROM `__PROJECT_ID__.__GOLD_DATASET__.transactions`
  WHERE flow_type = 'expense' AND canonical_category IS NOT NULL
  GROUP BY vendor_name, canonical_category
), ranked AS (
  SELECT
    v.*,
    SUM(v.spend) OVER () AS all_spend,
    SUM(v.spend) OVER (ORDER BY v.spend DESC, v.vendor_name
                       ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS running_spend,
    ROW_NUMBER() OVER (ORDER BY v.spend DESC, v.vendor_name) AS rank
  FROM expense_vendors AS v
)
SELECT
  r.rank,
  r.vendor_name,
  r.source,
  r.txns,
  r.spend,
  -- Progress bar: share of unreviewed expense spend cleared through this row.
  ROUND(r.running_spend / r.all_spend * 100, 1) AS running_pct_of_unreviewed_spend,
  -- The suggestion. Copilot categories were reviewed by hand historically, so a
  -- Copilot majority is the strongest evidence available; fall back to whatever
  -- the vendor currently resolves to only when Copilot never saw this merchant.
  COALESCE(cp.category_id, cur_cat.category_id) AS suggested_category_id,
  COALESCE(cp.category_name, cur.canonical_category) AS suggested_category,
  CASE
    WHEN cp.category_name IS NOT NULL THEN CONCAT('copilot x', CAST(cp.votes AS STRING))
    ELSE 'current (no copilot evidence)'
  END AS suggestion_basis,
  cur.canonical_category AS current_category,
  cp.category_name IS NOT NULL
    AND cur.canonical_category IS NOT NULL
    AND cp.category_name != cur.canonical_category AS disagrees,
  -- What to do with this row. The one rule that matters: map merchants that
  -- RECUR, never one-offs. A mapping applies confidently to every future
  -- transaction and nothing flags it, so a wrong one is worse than none.
  CASE
    WHEN mv.mapped_name IS NOT NULL THEN CONCAT('ALIAS to "', mv.mapped_name, '"')
    -- Copilot already carries a category Steven reviewed by hand. Promoting a
    -- recurring one into the map makes it durable and independent of the export.
    WHEN r.source = 'copilot:reviewed' AND r.txns >= 2 THEN 'promote to vendor_map'
    WHEN r.source = 'copilot:reviewed'                 THEN 'leave (reviewed, one-off)'
    -- Tiller dumps what it cannot place into these two. Kindle Unlimited landed in
    -- Clothes & Grooming this way. Treat them as unknown, not as an answer.
    WHEN cur.canonical_category IN ('Clothes & Grooming', 'Unclassified')
      THEN 'SUSPECT — verify before trusting'
    WHEN r.txns >= 2   THEN 'map (recurring merchant)'
    WHEN r.spend >= 500 THEN 'review this transaction (one-off, large)'
    ELSE 'accept or catch by rule (one-off, small)'
  END AS suggested_action,
  r.last_seen
FROM ranked AS r
LEFT JOIN copilot_votes AS cp ON cp.vendor_name = r.vendor_name AND cp.rnk = 1
LEFT JOIN current_votes AS cur ON cur.vendor_name = r.vendor_name AND cur.rnk = 1
LEFT JOIN `__PROJECT_ID__.__GOLD_DATASET__.categories` AS cur_cat
  ON cur_cat.active AND cur_cat.category_name = cur.canonical_category
-- Longest matching mapped prefix, so "Sabrinas Cafe Sou" points at "Sabrinas Cafe"
-- rather than at some shorter accidental match.
LEFT JOIN mapped AS mv
  ON STARTS_WITH(LOWER(REGEXP_REPLACE(r.vendor_name, r'[^a-zA-Z0-9]', '')), mv.mapped_key)
 AND LENGTH(mv.mapped_key) >= 6
 -- Never suggest aliasing a merchant to itself. A merchant mapped since the last
 -- rebuild still reports classification_source = 'tiller', so without this it
 -- appears in the queue matched against its own map row and reads as an alias.
 AND mv.mapped_key != LOWER(REGEXP_REPLACE(r.vendor_name, r'[^a-zA-Z0-9]', ''))
QUALIFY ROW_NUMBER() OVER (
  PARTITION BY r.vendor_name ORDER BY LENGTH(COALESCE(mv.mapped_key, '')) DESC
) = 1
ORDER BY r.spend DESC, r.vendor_name
LIMIT 300;
