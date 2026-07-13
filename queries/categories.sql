SELECT
  category_id,
  category_name,
  parent_category,
  category_kind,
  description,
  active
FROM `__PROJECT_ID__.__GOLD_DATASET__.categories`
ORDER BY category_kind, parent_category, category_name;

