SELECT
  observed_vendor_name,
  canonical_vendor_name,
  mapping_method,
  confidence,
  review_status,
  observed_categories,
  transaction_count,
  lifetime_spend,
  first_seen,
  last_seen
FROM `__PROJECT_ID__.__GOLD_DATASET__.vendor_canonical_review`
ORDER BY transaction_count DESC, lifetime_spend DESC;
