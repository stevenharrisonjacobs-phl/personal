-- Where categories actually come from. The one number to watch is the `tiller`
-- share of expense SPEND — that is the unreviewed remainder the classification
-- review exists to drive down.
--
-- Reported for expenses only. Transaction counts across ALL rows flatter the
-- picture, because much of the Tiller residual is investment and transfer
-- plumbing that `flow_type` already excludes from spending.
--
-- Precedence that produced these values (one chain, defined in sql/gold.sql):
--   per-txn override > vendor_category_map > rule > Copilot (reviewed) > Tiller
SELECT
  CASE
    WHEN classification_source = 'override'         THEN '1. per-txn override'
    WHEN classification_source = 'vendor_map'       THEN '2. vendor_map (deliberate)'
    WHEN classification_source LIKE 'rule:%'        THEN '3. rule (deliberate)'
    WHEN classification_source = 'copilot:reviewed' THEN '4. copilot (hand-reviewed window)'
    WHEN classification_source = 'tiller'           THEN '5. tiller (UNREVIEWED — drive to zero)'
    ELSE '6. uncategorized'
  END AS source,
  COUNT(*) AS txns,
  ROUND(100 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct_txns,
  ROUND(SUM(spend_amount), 2) AS spend,
  ROUND(100 * SUM(spend_amount) / SUM(SUM(spend_amount)) OVER (), 1) AS pct_spend,
  COUNT(DISTINCT vendor_name) AS merchants
FROM `__PROJECT_ID__.__GOLD_DATASET__.transactions`
WHERE flow_type = 'expense'
GROUP BY source
ORDER BY source;
