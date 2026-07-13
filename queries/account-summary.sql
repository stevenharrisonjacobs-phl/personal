SELECT
  account_name,
  institution,
  account_type,
  account_class,
  balance_as_of,
  signed_balance,
  transaction_count,
  lifetime_spend,
  lifetime_income,
  has_balance_history,
  has_transactions
FROM `__PROJECT_ID__.__GOLD_DATASET__.accounts`
ORDER BY account_class, account_name;

