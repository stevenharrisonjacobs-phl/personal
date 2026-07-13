SELECT
  COALESCE(description, full_description) AS merchant,
  COUNT(*) AS transactions,
  ROUND(SUM(spend_amount), 2) AS spending,
  ROUND(AVG(spend_amount), 2) AS average_spend
FROM `__PROJECT_ID__.__FINANCE_DATASET__.v_spending`
WHERE category = 'Uncategorized'
  AND transaction_date >= DATE_SUB(CURRENT_DATE(), INTERVAL 90 DAY)
  AND NOT is_transfer
GROUP BY merchant
ORDER BY spending DESC
LIMIT 50;

