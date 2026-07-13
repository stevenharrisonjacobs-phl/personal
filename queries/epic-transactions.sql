SELECT
  epic_name,
  epic_type,
  transaction_date,
  source_name,
  source_amount,
  match_status,
  transaction_key
FROM `__PROJECT_ID__.__GOLD_DATASET__.epic_transactions`
ORDER BY transaction_date DESC, epic_name;
