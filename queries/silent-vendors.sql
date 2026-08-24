-- The silent-vendor check: vendors that billed reliably and then STOPPED,
-- while the feed itself stayed healthy.
--
-- A stale feed is only half the failure mode. The other half is absence, and
-- absence raises no alert on its own — that is how three mortgage payments went
-- unnoticed for a quarter. A query has to look for it deliberately.
--
-- `known_state` exists for the same reason it exists in source-freshness.sql:
-- a cancelled subscription, a seasonal biller between terms, and a genuinely
-- dropped payment all look identical from here — each is just a vendor that
-- stopped. Without this the nightly run rediscovers the same settled items and
-- asks about them again. Fix the report, not the answer.
--
-- Amounts are deliberately bucketed, not printed: this file is committed.
WITH monthly AS (
  SELECT
    vendor_name,
    DATE_TRUNC(transaction_date, MONTH) AS mo,
    SUM(flow_expense_amount) AS mo_amount
  FROM `__PROJECT_ID__.__GOLD_DATASET__.transactions`
  WHERE flow_type = 'expense'
    AND flow_expense_amount > 0
    AND vendor_name IS NOT NULL
    AND transaction_date >= DATE_SUB(DATE_TRUNC(CURRENT_DATE(), MONTH), INTERVAL 12 MONTH)
    AND transaction_date <  DATE_TRUNC(CURRENT_DATE(), MONTH)
  GROUP BY vendor_name, mo
),
profile AS (
  SELECT
    vendor_name,
    COUNT(DISTINCT mo) AS months_billed_12,
    AVG(mo_amount) AS avg_monthly_amount,
    SAFE_DIVIDE(STDDEV(mo_amount), AVG(mo_amount)) AS amount_cv
  FROM monthly
  GROUP BY vendor_name
),
last_seen AS (
  SELECT
    vendor_name,
    MAX(transaction_date) AS last_charge,
    DATE_DIFF(CURRENT_DATE(), MAX(transaction_date), DAY) AS days_silent
  FROM `__PROJECT_ID__.__GOLD_DATASET__.transactions`
  WHERE flow_type = 'expense' AND flow_expense_amount > 0 AND vendor_name IS NOT NULL
  GROUP BY vendor_name
)
SELECT
  p.vendor_name,
  p.months_billed_12,
  ROUND(p.amount_cv, 2) AS amount_cv,          -- 0.00 = identical every month
  CASE
    WHEN p.avg_monthly_amount >= 1000 THEN 'large'
    WHEN p.avg_monthly_amount >=  100 THEN 'medium'
    ELSE 'small'
  END AS monthly_size,
  l.last_charge,
  l.days_silent,
  CASE
    -- Ruled 2026-08-18. Settled; do NOT raise these again.
    WHEN REGEXP_CONTAINS(p.vendor_name, r'(?i)pnc mortgage')
      THEN 'SETTLED — Jun-Jul gap closed by the Aug 12 catch-up payment; autopay armed'
    -- Seasonal billers: silence between terms is correct, not a failure.
    WHEN REGEXP_CONTAINS(p.vendor_name, r'(?i)beacon preschool')
      THEN 'SEASONAL — school year bills ~Oct-May; summer silence expected'
    WHEN REGEXP_CONTAINS(p.vendor_name, r'(?i)tall pines')
      THEN 'SEASONAL — camp installments bill ~Oct-Jul; late-summer silence expected'
    ELSE NULL
  END AS known_state
FROM profile p
JOIN last_seen l USING (vendor_name)
WHERE p.months_billed_12 >= 6      -- billed in at least half the last 12 months
  AND p.amount_cv <= 0.60          -- at a reasonably consistent amount
  AND l.days_silent >= 45          -- past a monthly window with room to spare
ORDER BY p.avg_monthly_amount DESC;
