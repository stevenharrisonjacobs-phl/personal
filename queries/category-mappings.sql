SELECT
  source_system,
  source_parent_category,
  source_category,
  c.category_name AS canonical_category,
  c.parent_category AS canonical_parent,
  c.category_kind,
  a.active
FROM `__PROJECT_ID__.__GOLD_DATASET__.category_aliases` AS a
JOIN `__PROJECT_ID__.__GOLD_DATASET__.categories` AS c USING (category_id)
ORDER BY source_system, source_parent_category, source_category;

