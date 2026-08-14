SELECT
  owner,
  source,
  component,
  income_bucket,
  monthly_amount,
  annualized_amount,
  effective_from,
  as_of_statement,
  notes
FROM `__PROJECT_ID__.__FINANCE_DATASET__.v_manual_income`
ORDER BY owner, source, component;
