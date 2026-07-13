CREATE TABLE IF NOT EXISTS `__PROJECT_ID__.__FINANCE_DATASET__.classification_rules` (
  rule_id STRING NOT NULL,
  priority INT64 NOT NULL,
  description_regex STRING,
  account_regex STRING,
  min_absolute_amount NUMERIC,
  max_absolute_amount NUMERIC,
  direction STRING,
  category STRING NOT NULL,
  subcategory STRING,
  notes STRING,
  enabled BOOL NOT NULL,
  created_at TIMESTAMP NOT NULL
);

CREATE TABLE IF NOT EXISTS `__PROJECT_ID__.__FINANCE_DATASET__.transaction_overrides` (
  transaction_key STRING NOT NULL,
  category STRING NOT NULL,
  subcategory STRING,
  notes STRING,
  created_at TIMESTAMP NOT NULL
);

CREATE OR REPLACE VIEW `__PROJECT_ID__.__FINANCE_DATASET__.v_transactions_classified` AS
WITH rule_matches AS (
  SELECT
    t.transaction_key,
    r.rule_id,
    r.category,
    r.subcategory,
    ROW_NUMBER() OVER (
      PARTITION BY t.transaction_key
      ORDER BY r.priority, r.rule_id
    ) AS match_rank
  FROM `__PROJECT_ID__.__FINANCE_DATASET__.transactions` AS t
  JOIN `__PROJECT_ID__.__FINANCE_DATASET__.classification_rules` AS r
    ON r.enabled
   AND (r.description_regex IS NULL OR REGEXP_CONTAINS(COALESCE(t.description, t.full_description, ''), r.description_regex))
   AND (r.account_regex IS NULL OR REGEXP_CONTAINS(COALESCE(t.account_name, ''), r.account_regex))
   AND (r.min_absolute_amount IS NULL OR ABS(t.amount) >= r.min_absolute_amount)
   AND (r.max_absolute_amount IS NULL OR ABS(t.amount) <= r.max_absolute_amount)
   AND (
     r.direction IS NULL
     OR LOWER(r.direction) = 'any'
     OR (LOWER(r.direction) = 'expense' AND t.amount < 0)
     OR (LOWER(r.direction) = 'income' AND t.amount > 0)
   )
), overrides AS (
  SELECT * EXCEPT(override_rank)
  FROM (
    SELECT
      o.*,
      ROW_NUMBER() OVER (
        PARTITION BY transaction_key
        ORDER BY created_at DESC
      ) AS override_rank
    FROM `__PROJECT_ID__.__FINANCE_DATASET__.transaction_overrides` AS o
  )
  WHERE override_rank = 1
)
SELECT
  t.* EXCEPT(source_payload),
  COALESCE(NULLIF(o.category, ''), NULLIF(r.category, ''), NULLIF(t.source_category, ''), 'Uncategorized') AS category,
  COALESCE(NULLIF(o.subcategory, ''), NULLIF(r.subcategory, '')) AS subcategory,
  CASE
    WHEN o.transaction_key IS NOT NULL THEN 'override'
    WHEN r.rule_id IS NOT NULL THEN CONCAT('rule:', r.rule_id)
    WHEN NULLIF(t.source_category, '') IS NOT NULL THEN 'tiller'
    ELSE 'uncategorized'
  END AS classification_source
FROM `__PROJECT_ID__.__FINANCE_DATASET__.transactions` AS t
LEFT JOIN overrides AS o USING (transaction_key)
LEFT JOIN rule_matches AS r
  ON t.transaction_key = r.transaction_key
 AND r.match_rank = 1;

CREATE OR REPLACE VIEW `__PROJECT_ID__.__FINANCE_DATASET__.v_spending` AS
SELECT
  * EXCEPT(amount),
  amount,
  -amount AS spend_amount,
  REGEXP_CONTAINS(LOWER(COALESCE(category, '')), r'transfer|credit card payment') AS is_transfer
FROM `__PROJECT_ID__.__FINANCE_DATASET__.v_transactions_classified`
WHERE amount < 0;

CREATE OR REPLACE VIEW `__PROJECT_ID__.__FINANCE_DATASET__.v_current_balances` AS
SELECT
  * EXCEPT(source_payload),
  CASE
    WHEN account_class = 'liability' THEN -ABS(balance)
    ELSE balance
  END AS signed_balance
FROM `__PROJECT_ID__.__FINANCE_DATASET__.balance_history`
QUALIFY ROW_NUMBER() OVER (
  PARTITION BY COALESCE(account_id, account_name)
  ORDER BY balance_date DESC, balance_time_utc DESC, balance_key DESC
) = 1;

CREATE OR REPLACE VIEW `__PROJECT_ID__.__FINANCE_DATASET__.v_monthly_net_worth` AS
WITH month_end AS (
  SELECT
    LAST_DAY(balance_date, MONTH) AS month,
    account_id,
    account_name,
    account_class,
    balance,
    ROW_NUMBER() OVER (
      PARTITION BY LAST_DAY(balance_date, MONTH), COALESCE(account_id, account_name)
      ORDER BY balance_date DESC, balance_time_utc DESC, balance_key DESC
    ) AS row_rank
  FROM `__PROJECT_ID__.__FINANCE_DATASET__.balance_history`
)
SELECT
  month,
  SUM(CASE WHEN account_class = 'liability' THEN -ABS(balance) ELSE balance END) AS net_worth,
  SUM(CASE WHEN account_class = 'liability' THEN 0 ELSE balance END) AS assets,
  SUM(CASE WHEN account_class = 'liability' THEN ABS(balance) ELSE 0 END) AS liabilities
FROM month_end
WHERE row_rank = 1
GROUP BY month;

