SELECT
  account_name,
  institution,
  account_type,
  account_class,
  balance_date,
  ROUND(signed_balance, 2) AS signed_balance
FROM `__PROJECT_ID__.__FINANCE_DATASET__.v_current_balances`
ORDER BY account_class, account_name;

