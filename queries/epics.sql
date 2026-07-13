SELECT
  epic_name,
  epic_type,
  inferred_status,
  start_date,
  end_date,
  transaction_count,
  linked_transaction_count,
  unlinked_transaction_count,
  net_spend
FROM `__PROJECT_ID__.__GOLD_DATASET__.epics`
ORDER BY start_date DESC, epic_name;
