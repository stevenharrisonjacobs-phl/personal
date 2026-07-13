SELECT
  transaction_date,
  vendor_name,
  amount,
  canonical_category,
  flow_reason,
  flow_evidence_copilot_type,
  flow_evidence_copilot_category,
  paired_transaction_key,
  transaction_key
FROM `__PROJECT_ID__.__GOLD_DATASET__.transaction_flow_review`
ORDER BY ABS(amount) DESC, transaction_date DESC;
