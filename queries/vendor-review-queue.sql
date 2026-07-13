SELECT
  observed_vendor_name,
  canonical_vendor_name,
  confidence,
  observed_categories,
  transaction_count,
  lifetime_spend,
  first_seen,
  last_seen
FROM `__PROJECT_ID__.__GOLD_DATASET__.vendor_canonical_review`
WHERE review_status = 'needs_review'
ORDER BY transaction_count DESC, lifetime_spend DESC
LIMIT 250;
