SELECT
  vendor_name,
  primary_category,
  transaction_count,
  active_months,
  lifetime_spend,
  average_purchase,
  last_transaction_date
FROM `__PROJECT_ID__.__GOLD_DATASET__.vendors`
WHERE lifetime_spend > 0
ORDER BY lifetime_spend DESC
LIMIT 100;

