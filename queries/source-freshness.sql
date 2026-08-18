-- Per-account feed freshness, with the accounts Steven has already ruled on
-- labelled so they stop being re-flagged.
--
-- `known_state` is not decoration. A dead card and a broken feed look identical
-- from here — both are just an account that stopped posting — so without this
-- every run rediscovers the same three accounts and asks about them again.
-- Steven has been asked about these more than once; that is the bug this fixes.
SELECT
  account_name,
  account_number_masked,
  MAX(transaction_date) AS latest_transaction,
  DATE_DIFF(CURRENT_DATE(), MAX(transaction_date), DAY) AS days_since_latest,
  COUNTIF(transaction_date >= DATE_SUB(CURRENT_DATE(), INTERVAL 30 DAY)) AS txns_last_30d,
  CASE account_number_masked
    -- Ruled 2026-08-18. Do NOT raise these as stale feeds again.
    WHEN '2173' THEN 'EXPECTED — closed account, not a broken feed'
    WHEN '5823' THEN 'EXPECTED — closed account, not a broken feed'
    WHEN '7301' THEN 'EXPECTED — old 401(k), no longer contributed to'
    ELSE NULL
  END AS known_state
FROM `__PROJECT_ID__.__GOLD_DATASET__.transactions`
GROUP BY account_name, account_number_masked
ORDER BY days_since_latest DESC, account_name;
