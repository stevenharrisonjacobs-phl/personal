SELECT
  account_name,
  account_number_masked,
  MAX(transaction_date) AS latest_transaction,
  DATE_DIFF(CURRENT_DATE(), MAX(transaction_date), DAY) AS days_since_latest,
  COUNTIF(transaction_date >= DATE_SUB(CURRENT_DATE(), INTERVAL 30 DAY)) AS txns_last_30d
FROM `__PROJECT_ID__.__GOLD_DATASET__.transactions`
GROUP BY account_name, account_number_masked
ORDER BY days_since_latest DESC, account_name;
