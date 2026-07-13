SELECT
  alias_name,
  canonical_vendor_name,
  enabled,
  notes,
  created_at
FROM `__PROJECT_ID__.__GOLD_DATASET__.vendor_aliases`
ORDER BY canonical_vendor_name, alias_name;

