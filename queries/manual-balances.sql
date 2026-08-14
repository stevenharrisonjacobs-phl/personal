-- Off-Tiller accounts entered by hand (no bank feed). Amounts live only in
-- BigQuery (finance.manual_balances), never in git. refresh.sql re-stamps these
-- into balance_history each refresh so they count in current balances and net
-- worth. Update a figure with: UPDATE finance.manual_balances SET balance=...,
-- as_of_statement=... WHERE balance_id=...  (no code change, no redeploy).
SELECT
  balance_id,
  owner,
  account_name,
  account_number_masked,
  institution,
  account_type,
  account_class,
  balance,
  as_of_statement,
  notes
FROM `__PROJECT_ID__.__FINANCE_DATASET__.manual_balances`
ORDER BY owner, account_name;
