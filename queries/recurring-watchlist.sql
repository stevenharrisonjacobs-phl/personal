-- Recurring charges that have NOT hit their expected window — the "keep an
-- eye on" section of the daily spend check-in per the check-in plan.
--
-- Cadence is inferred from vendor history in gold.transactions: a vendor that
-- posted an expense in at least 4 of the last 6 full months is treated as
-- monthly. It is flagged when its usual posting day (median day-of-month) plus
-- a 5-day grace period has passed this month with no transaction — or when a
-- full cadence interval plus grace has passed since its last hit.
--
-- The curated expectations in the spend-checkin skill's
-- context/expected-recurrings.md are merged on top of this by the skill; this
-- query is the history-derived floor. This is exactly the guard for the
-- known failure mode: three mortgage payments once went unnoticed for a
-- quarter because nothing watched for an ABSENT transaction.
WITH monthly_vendors AS (
  SELECT
    vendor_name,
    COUNT(DISTINCT DATE_TRUNC(transaction_date, MONTH)) AS active_months,
    MAX(transaction_date) AS last_hit,
    CAST(APPROX_QUANTILES(EXTRACT(DAY FROM transaction_date), 2)[OFFSET(1)] AS INT64) AS usual_day,
    ROUND(AVG(flow_expense_amount), 0) AS typical_amount
  FROM `__PROJECT_ID__.__GOLD_DATASET__.transactions`
  WHERE flow_type = 'expense'
    AND transaction_date >= DATE_SUB(DATE_TRUNC(CURRENT_DATE(), MONTH), INTERVAL 6 MONTH)
    AND transaction_date < DATE_TRUNC(CURRENT_DATE(), MONTH)
    AND vendor_name IS NOT NULL
  GROUP BY vendor_name
  HAVING active_months >= 4
),
judged AS (
  -- Each watch condition computed exactly once; the display string, the row
  -- filter, and the sort all read these flags instead of restating them.
  SELECT
    v.*,
    (EXTRACT(DAY FROM CURRENT_DATE()) > v.usual_day + 5
     AND v.last_hit < DATE_TRUNC(CURRENT_DATE(), MONTH)) AS overdue_this_month,
    DATE_DIFF(CURRENT_DATE(), v.last_hit, DAY) > 35 AS overdue_full_cycle,
    (EXTRACT(DAY FROM CURRENT_DATE()) BETWEEN v.usual_day - 3 AND v.usual_day + 5
     AND v.last_hit < DATE_TRUNC(CURRENT_DATE(), MONTH)) AS upcoming_window
  FROM monthly_vendors AS v
)
SELECT
  vendor_name,
  usual_day AS usual_day_of_month,
  last_hit,
  DATE_DIFF(CURRENT_DATE(), last_hit, DAY) AS days_since_last,
  typical_amount,
  CASE
    WHEN overdue_this_month
      THEN CONCAT('overdue — usually hits by day ', CAST(usual_day AS STRING), ', nothing this month')
    WHEN overdue_full_cycle
      THEN 'overdue — more than a full cycle since last hit'
    ELSE CONCAT('upcoming — expected around day ', CAST(usual_day AS STRING))
  END AS watch_state
FROM judged
WHERE overdue_this_month OR overdue_full_cycle OR upcoming_window
ORDER BY
  IF(overdue_this_month OR overdue_full_cycle, 0, 1),
  typical_amount DESC;
