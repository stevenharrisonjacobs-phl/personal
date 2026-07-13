SELECT
  DATE_TRUNC(transaction_date, MONTH) AS month,
  category,
  ROUND(SUM(spend_amount), 2) AS spending,
  COUNT(*) AS transactions
FROM `__PROJECT_ID__.__FINANCE_DATASET__.v_spending`
WHERE transaction_date >= DATE_SUB(CURRENT_DATE(), INTERVAL 12 MONTH)
  AND NOT is_transfer
GROUP BY month, category
ORDER BY month DESC, spending DESC;

