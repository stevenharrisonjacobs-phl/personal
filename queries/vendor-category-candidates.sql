WITH expense_vendors AS (
  SELECT
    vendor_name,
    COUNT(*) AS txns,
    ROUND(SUM(spend_amount), 2) AS spend,
    MAX(transaction_date) AS last_seen
  FROM `__PROJECT_ID__.__GOLD_DATASET__.transactions`
  WHERE flow_type = 'expense'
    AND vendor_name IS NOT NULL
    AND NOT STARTS_WITH(vendor_name, 'Unresolved Vendor ')
  GROUP BY vendor_name
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
    SUM(v.txns) OVER () AS all_txns,
    SUM(v.txns) OVER (ORDER BY v.txns DESC, v.vendor_name
                      ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS running_txns,
    ROW_NUMBER() OVER (ORDER BY v.txns DESC, v.vendor_name) AS rank
  FROM expense_vendors AS v
)
SELECT
  r.rank,
  r.vendor_name,
  r.txns,
  r.spend,
  ROUND(r.running_txns / r.all_txns * 100, 1) AS running_coverage_pct,
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
  r.last_seen
FROM ranked AS r
LEFT JOIN copilot_votes AS cp ON cp.vendor_name = r.vendor_name AND cp.rnk = 1
LEFT JOIN current_votes AS cur ON cur.vendor_name = r.vendor_name AND cur.rnk = 1
LEFT JOIN `__PROJECT_ID__.__GOLD_DATASET__.categories` AS cur_cat
  ON cur_cat.active AND cur_cat.category_name = cur.canonical_category
LEFT JOIN `__PROJECT_ID__.__GOLD_DATASET__.vendor_category_map` AS vm
  ON vm.enabled AND vm.vendor_name = r.vendor_name
WHERE vm.vendor_name IS NULL
ORDER BY r.txns DESC, r.vendor_name
LIMIT 250;
