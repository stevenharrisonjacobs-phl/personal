SELECT
  transaction_date,
  vendor_name,
  amount,
  flow_type,
  canonical_category,
  deterministic_flags,
  severity,
  anomaly_types,
  rationale,
  suggested_flow_type,
  suggested_category_id,
  suggested_vendor_name,
  reviewed_at
FROM `__PROJECT_ID__.__GOLD_DATASET__.transaction_anomaly_review_queue`
ORDER BY
  CASE severity
    WHEN 'critical' THEN 1
    WHEN 'high' THEN 2
    WHEN 'medium' THEN 3
    WHEN 'low' THEN 4
    ELSE 5
  END,
  ABS(amount) DESC,
  transaction_date DESC;
