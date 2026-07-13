WITH transactions AS (
  SELECT *
  FROM `__PROJECT_ID__.__GOLD_DATASET__.transactions`
), vendor_stats AS (
  SELECT
    vendor_id,
    COUNTIF(flow_type = 'expense') AS expense_count,
    AVG(IF(flow_type = 'expense', flow_expense_amount, NULL)) AS average_expense,
    STDDEV_SAMP(IF(flow_type = 'expense', flow_expense_amount, NULL)) AS expense_stddev
  FROM transactions
  GROUP BY vendor_id
), category_stats AS (
  SELECT
    category_id,
    APPROX_QUANTILES(IF(flow_type = 'expense', flow_expense_amount, NULL), 100 IGNORE NULLS)[OFFSET(99)] AS expense_p99
  FROM transactions
  GROUP BY category_id
), duplicate_counts AS (
  SELECT
    transaction_date,
    COALESCE(account_id, account_name, '') AS account_identity,
    vendor_id,
    amount,
    COUNT(*) AS duplicate_count
  FROM transactions
  GROUP BY transaction_date, account_identity, vendor_id, amount
), unreviewed AS (
  SELECT
    t.*,
    COALESCE(v.expense_count, 0) AS vendor_expense_count,
    v.average_expense AS vendor_average_expense,
    v.expense_stddev AS vendor_expense_stddev,
    c.expense_p99 AS category_expense_p99,
    COALESCE(d.duplicate_count, 1) AS duplicate_count
  FROM transactions AS t
  LEFT JOIN vendor_stats AS v USING (vendor_id)
  LEFT JOIN category_stats AS c USING (category_id)
  LEFT JOIN duplicate_counts AS d
    ON d.transaction_date = t.transaction_date
   AND d.account_identity = COALESCE(t.account_id, t.account_name, '')
   AND d.vendor_id = t.vendor_id
   AND d.amount = t.amount
  LEFT JOIN `__PROJECT_ID__.__GOLD_DATASET__.transaction_onboarding_reviews` AS r
    ON r.transaction_key = t.transaction_key
   AND r.review_version = @review_version
  WHERE r.transaction_key IS NULL
    AND COALESCE(t.date_added, t.transaction_date) >= DATE_SUB(CURRENT_DATE(), INTERVAL @lookback_days DAY)
), flagged AS (
  SELECT
    *,
    ARRAY_CONCAT(
      IF(flow_type = 'needs_review', ['flow_needs_review'], []),
      IF(category_id = 'unclassified', ['unclassified_category'], []),
      IF(flow_confidence < 0.80, ['low_flow_confidence'], []),
      IF(vendor_expense_count = 1, ['new_vendor'], []),
      IF(
        flow_type = 'expense'
        AND vendor_expense_count >= 5
        AND flow_expense_amount > GREATEST(
          500,
          COALESCE(vendor_average_expense, 0) + 4 * COALESCE(vendor_expense_stddev, 0)
        ),
        ['vendor_amount_outlier'],
        []
      ),
      IF(
        flow_type = 'expense'
        AND flow_expense_amount > 500
        AND flow_expense_amount > COALESCE(category_expense_p99, 0),
        ['category_amount_outlier'],
        []
      ),
      IF(duplicate_count > 1, ['possible_duplicate'], [])
    ) AS deterministic_flags
  FROM unreviewed
)
SELECT
  transaction_key,
  transaction_date,
  LEFT(COALESCE(description, ''), 180) AS description,
  vendor_name,
  amount,
  flow_type,
  flow_confidence,
  category_id,
  canonical_category,
  parent_category,
  vendor_expense_count,
  ROUND(vendor_average_expense, 2) AS vendor_average_expense,
  ROUND(vendor_expense_stddev, 2) AS vendor_expense_stddev,
  ROUND(category_expense_p99, 2) AS category_expense_p99,
  duplicate_count,
  deterministic_flags
FROM flagged
ORDER BY transaction_date, transaction_key
