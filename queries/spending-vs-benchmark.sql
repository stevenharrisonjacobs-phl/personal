WITH base AS (
  SELECT
    COALESCE(canonical_category, category, 'Uncategorized') AS category,
    transaction_date,
    -amount AS spend
  FROM `__PROJECT_ID__.__GOLD_DATASET__.transactions`
  WHERE flow_type = 'expense'
    AND COALESCE(institution, '') != 'Mercury'
    AND COALESCE(canonical_category, category) != 'Internal Transfer'
    AND transaction_date >= DATE_SUB(CURRENT_DATE(), INTERVAL 14 MONTH)
)
SELECT
  category,
  -- recent = last 6 weeks
  ROUND(SUM(IF(transaction_date >= DATE_SUB(CURRENT_DATE(), INTERVAL 6 WEEK), spend, 0)), 0) AS recent_total,
  ROUND(SUM(IF(transaction_date >= DATE_SUB(CURRENT_DATE(), INTERVAL 6 WEEK), spend, 0)) / 6.0, 0) AS recent_per_week,
  -- usual = trailing 12 months excluding the recent 6 weeks -> 46 weeks
  ROUND(SUM(IF(transaction_date >= DATE_SUB(CURRENT_DATE(), INTERVAL 12 MONTH)
              AND transaction_date <  DATE_SUB(CURRENT_DATE(), INTERVAL 6 WEEK), spend, 0)) / 46.0, 0) AS usual_per_week,
  -- last year = the same 6 calendar weeks one year ago (independent window, may overlap 'usual')
  ROUND(SUM(IF(transaction_date >= DATE_SUB(DATE_SUB(CURRENT_DATE(), INTERVAL 1 YEAR), INTERVAL 6 WEEK)
              AND transaction_date <  DATE_SUB(CURRENT_DATE(), INTERVAL 1 YEAR), spend, 0)) / 6.0, 0) AS last_year_per_week
FROM base
GROUP BY category
HAVING recent_total > 0
    OR SUM(IF(transaction_date >= DATE_SUB(CURRENT_DATE(), INTERVAL 12 MONTH)
             AND transaction_date <  DATE_SUB(CURRENT_DATE(), INTERVAL 6 WEEK), spend, 0)) > 0
ORDER BY recent_total DESC;
