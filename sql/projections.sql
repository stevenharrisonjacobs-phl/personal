-- Forward-looking layer: assumptions, accruals, and projection.
--
-- Three ideas, deliberately separated:
--   assumptions  - versioned inputs (tax rate, income streams). Effective-dated so
--                  a past forecast can be re-run with what was believed at the time.
--   accruals     - PRE-amortization. Recognise a cost as it is incurred rather than
--                  when it is paid (estimated taxes accrue monthly; the quarterly
--                  cheque is a settlement, not new expense).
--   projection   - forward months, shaped by cost_behavior and seasonality.

CREATE TABLE IF NOT EXISTS `__PROJECT_ID__.__FINANCE_DATASET__.assumptions` (
  assumption_key STRING NOT NULL,
  value_numeric NUMERIC NOT NULL,
  effective_from DATE NOT NULL,
  effective_to DATE,               -- NULL = still current
  confidence STRING,               -- high | med | low
  notes STRING,
  enabled BOOL NOT NULL,
  created_at TIMESTAMP NOT NULL
);

MERGE `__PROJECT_ID__.__FINANCE_DATASET__.assumptions` AS target
USING UNNEST([
  STRUCT('se_tax_rate' AS assumption_key, NUMERIC '0.37' AS value_numeric,
         DATE '2026-03-15' AS effective_from, CAST(NULL AS DATE) AS effective_to,
         'med' AS confidence,
         'Blended federal+state+SE on consulting income. Needs a CPA, especially Philadelphia BIRT/NPT.' AS notes),
  STRUCT('income.bobsled', NUMERIC '10000', DATE '2026-03-15', CAST(NULL AS DATE), 'med',
         'Contract with former employer. Steady but at-risk.'),
  STRUCT('income.snapfix', NUMERIC '2500', DATE '2026-06-01', CAST(NULL AS DATE), 'low',
         'Design partnership. May not repeat.'),
  STRUCT('income.hannah_net', NUMERIC '8240', DATE '2026-01-01', CAST(NULL AS DATE), 'high',
         'Newco take-home, already net of 401k deferral.'),
  STRUCT('income.family_distribution', NUMERIC '1000', DATE '2025-01-01', CAST(NULL AS DATE), 'high',
         'Monthly distribution from Hannah\'s father. 19 consecutive payments.'),
  STRUCT('business.tools_monthly', NUMERIC '400', DATE '2026-03-15', CAST(NULL AS DATE), 'med',
         'Plum Growth software/tooling, deducted before the tax rate is applied.')
]) AS seed
ON target.assumption_key = seed.assumption_key AND target.effective_from = seed.effective_from
WHEN MATCHED THEN UPDATE SET
  value_numeric = seed.value_numeric,
  effective_to = seed.effective_to,
  confidence = seed.confidence,
  notes = seed.notes,
  enabled = TRUE
WHEN NOT MATCHED THEN
  INSERT (assumption_key, value_numeric, effective_from, effective_to, confidence, notes, enabled, created_at)
  VALUES (seed.assumption_key, seed.value_numeric, seed.effective_from, seed.effective_to,
          seed.confidence, seed.notes, TRUE, CURRENT_TIMESTAMP());

CREATE OR REPLACE VIEW `__PROJECT_ID__.__FINANCE_DATASET__.v_assumptions_current` AS
SELECT assumption_key, value_numeric, effective_from, effective_to, confidence, notes
FROM `__PROJECT_ID__.__FINANCE_DATASET__.assumptions`
WHERE enabled
  AND effective_from <= CURRENT_DATE()
  AND (effective_to IS NULL OR effective_to >= CURRENT_DATE());

-- Accruals: recognise cost as incurred, before it is paid.
--   method 'rate_of_income'  - rate x that month's business revenue (estimated taxes)
--   method 'fixed_monthly'   - flat amount per month (a known future obligation)
-- rate_assumption_key points at finance.assumptions so the rate has one home.
CREATE TABLE IF NOT EXISTS `__PROJECT_ID__.__FINANCE_DATASET__.accruals` (
  accrual_id STRING NOT NULL,
  label STRING NOT NULL,
  category_id STRING NOT NULL,
  method STRING NOT NULL,
  fixed_amount NUMERIC,
  rate_assumption_key STRING,
  start_date DATE NOT NULL,
  end_date DATE,
  notes STRING,
  enabled BOOL NOT NULL,
  created_at TIMESTAMP NOT NULL
);

MERGE `__PROJECT_ID__.__FINANCE_DATASET__.accruals` AS target
USING UNNEST([
  STRUCT('se-tax-reserve' AS accrual_id,
         'Self-employment tax reserve' AS label,
         'taxes' AS category_id,
         'rate_of_income' AS method,
         CAST(NULL AS NUMERIC) AS fixed_amount,
         'se_tax_rate' AS rate_assumption_key,
         DATE '2026-03-15' AS start_date,
         CAST(NULL AS DATE) AS end_date,
         'Accrues on Plum Growth revenue net of tooling. Quarterly payments settle this, they are not additional cost.' AS notes)
]) AS seed
ON target.accrual_id = seed.accrual_id
WHEN MATCHED THEN UPDATE SET
  label = seed.label, category_id = seed.category_id, method = seed.method,
  fixed_amount = seed.fixed_amount, rate_assumption_key = seed.rate_assumption_key,
  start_date = seed.start_date, end_date = seed.end_date, notes = seed.notes, enabled = TRUE
WHEN NOT MATCHED THEN
  INSERT (accrual_id, label, category_id, method, fixed_amount, rate_assumption_key,
          start_date, end_date, notes, enabled, created_at)
  VALUES (seed.accrual_id, seed.label, seed.category_id, seed.method, seed.fixed_amount,
          seed.rate_assumption_key, seed.start_date, seed.end_date, seed.notes, TRUE, CURRENT_TIMESTAMP());

-- Monthly business revenue, the basis for rate_of_income accruals.
CREATE OR REPLACE VIEW `__PROJECT_ID__.__GOLD_DATASET__.v_business_revenue_monthly` AS
SELECT
  DATE_TRUNC(transaction_date, MONTH) AS month,
  SUM(CASE WHEN flow_type IN ('earned_income', 'refund_reimbursement') THEN amount ELSE 0 END) AS revenue
FROM `__PROJECT_ID__.__GOLD_DATASET__.transactions`
WHERE institution = 'Mercury' AND amount > 0
GROUP BY month;

-- Synthetic monthly cost rows generated by the accrual rules.
CREATE OR REPLACE VIEW `__PROJECT_ID__.__GOLD_DATASET__.v_accrued_costs` AS
WITH months AS (
  SELECT month FROM `__PROJECT_ID__.__GOLD_DATASET__.v_business_revenue_monthly`
  UNION DISTINCT
  SELECT DATE_TRUNC(transaction_date, MONTH) FROM `__PROJECT_ID__.__GOLD_DATASET__.transactions`
), a AS (
  SELECT ac.*, c.category_name
  FROM `__PROJECT_ID__.__FINANCE_DATASET__.accruals` AS ac
  LEFT JOIN `__PROJECT_ID__.__GOLD_DATASET__.categories` AS c ON c.category_id = ac.category_id
  WHERE ac.enabled
)
SELECT
  a.accrual_id,
  a.label,
  a.category_name AS canonical_category,
  m.month AS accrued_month,
  CASE a.method
    WHEN 'fixed_monthly' THEN a.fixed_amount
    WHEN 'rate_of_income' THEN
      GREATEST(COALESCE(r.revenue, 0) - COALESCE(tools.value_numeric, 0), 0) * COALESCE(asm.value_numeric, 0)
    ELSE 0
  END AS accrued_amount,
  a.method
FROM a
JOIN months AS m
  ON m.month >= DATE_TRUNC(a.start_date, MONTH)
 AND (a.end_date IS NULL OR m.month <= DATE_TRUNC(a.end_date, MONTH))
LEFT JOIN `__PROJECT_ID__.__GOLD_DATASET__.v_business_revenue_monthly` AS r ON r.month = m.month
LEFT JOIN `__PROJECT_ID__.__FINANCE_DATASET__.assumptions` AS asm
  ON asm.assumption_key = a.rate_assumption_key AND asm.enabled
 AND m.month >= DATE_TRUNC(asm.effective_from, MONTH)
 AND (asm.effective_to IS NULL OR m.month <= DATE_TRUNC(asm.effective_to, MONTH))
LEFT JOIN `__PROJECT_ID__.__FINANCE_DATASET__.assumptions` AS tools
  ON tools.assumption_key = 'business.tools_monthly' AND tools.enabled
 AND m.month >= DATE_TRUNC(tools.effective_from, MONTH)
 AND (tools.effective_to IS NULL OR m.month <= DATE_TRUNC(tools.effective_to, MONTH));

-- Accrual-basis spending: amortized actuals, but for any category driven by an
-- accrual the actual payments are replaced by the accrual stream. Paying a
-- quarterly tax bill settles a liability that was already recognised; counting
-- both would double-count.
CREATE OR REPLACE VIEW `__PROJECT_ID__.__GOLD_DATASET__.v_spending_accrued` AS
WITH accrued_cats AS (
  SELECT DISTINCT c.category_name
  FROM `__PROJECT_ID__.__FINANCE_DATASET__.accruals` AS a
  JOIN `__PROJECT_ID__.__GOLD_DATASET__.categories` AS c ON c.category_id = a.category_id
  WHERE a.enabled
)
SELECT
  amortized_month AS month,
  canonical_category,
  cost_behavior,
  essential,
  vendor_name,
  amortized_amount AS amount,
  'actual' AS basis
FROM `__PROJECT_ID__.__GOLD_DATASET__.v_spending_amortized`
WHERE canonical_category NOT IN (SELECT category_name FROM accrued_cats)
UNION ALL
SELECT
  accrued_month AS month,
  canonical_category,
  'fixed' AS cost_behavior,
  TRUE AS essential,
  label AS vendor_name,
  accrued_amount AS amount,
  'accrual' AS basis
FROM `__PROJECT_ID__.__GOLD_DATASET__.v_accrued_costs`
WHERE accrued_amount > 0;

-- Forward projection. Method depends on how the category behaves:
--   fixed      - carry the last known run rate; these change by decree, not season
--   committed  - same month last year when history exists (catches School's Sep-May),
--                otherwise run rate
--   variable   - same month last year, otherwise trailing median
-- Reads the amortized view so a single annual bill in the lookback window cannot
-- distort the forecast. Trip epics are excluded from the seasonal baseline so last
-- year's holiday does not reappear as a recurring cost.
CREATE OR REPLACE VIEW `__PROJECT_ID__.__GOLD_DATASET__.v_projection` AS
WITH horizon AS (
  SELECT DATE_ADD(DATE_TRUNC(CURRENT_DATE(), MONTH), INTERVAL n MONTH) AS month
  FROM UNNEST(GENERATE_ARRAY(1, 18)) AS n
), hist AS (
  SELECT canonical_category, amortized_month AS month, SUM(amortized_amount) AS amount
  FROM `__PROJECT_ID__.__GOLD_DATASET__.v_spending_amortized`
  WHERE COALESCE(epic_name, '') NOT IN (
    SELECT COALESCE(epic_name, '') FROM `__PROJECT_ID__.__GOLD_DATASET__.epics` WHERE epic_type = 'trip'
  )
  GROUP BY 1, 2
), seasonal AS (
  SELECT canonical_category, EXTRACT(MONTH FROM month) AS cal_month, SUM(amount) AS amount
  FROM hist
  WHERE month >= DATE_SUB(DATE_TRUNC(CURRENT_DATE(), MONTH), INTERVAL 12 MONTH)
    AND month <  DATE_TRUNC(CURRENT_DATE(), MONTH)
  GROUP BY 1, 2
), runrate AS (
  SELECT canonical_category, APPROX_QUANTILES(amount, 2)[OFFSET(1)] AS median_amount
  FROM hist
  WHERE month >= DATE_SUB(DATE_TRUNC(CURRENT_DATE(), MONTH), INTERVAL 6 MONTH)
    AND month <  DATE_TRUNC(CURRENT_DATE(), MONTH)
  GROUP BY 1
), accrual_fwd AS (
  SELECT c.category_name, AVG(v.accrued_amount) AS avg_accrual
  FROM `__PROJECT_ID__.__GOLD_DATASET__.v_accrued_costs` AS v
  JOIN `__PROJECT_ID__.__GOLD_DATASET__.categories` AS c ON c.category_name = v.canonical_category
  WHERE v.accrued_month >= DATE_SUB(DATE_TRUNC(CURRENT_DATE(), MONTH), INTERVAL 6 MONTH)
  GROUP BY 1
)
SELECT
  h.month,
  c.category_name AS canonical_category,
  c.cost_behavior,
  c.cadence,
  c.essential,
  ROUND(COALESCE(
    af.avg_accrual,
    CASE c.cost_behavior
      WHEN 'fixed' THEN rr.median_amount
      ELSE COALESCE(s.amount, rr.median_amount)
    END,
    0), 2) AS projected_amount,
  CASE
    WHEN af.avg_accrual IS NOT NULL THEN 'accrual'
    WHEN c.cost_behavior = 'fixed' THEN 'run_rate'
    WHEN s.amount IS NOT NULL THEN 'same_month_last_year'
    WHEN rr.median_amount IS NOT NULL THEN 'run_rate'
    ELSE 'none'
  END AS method
FROM horizon AS h
CROSS JOIN `__PROJECT_ID__.__GOLD_DATASET__.categories` AS c
LEFT JOIN seasonal AS s
  ON s.canonical_category = c.category_name AND s.cal_month = EXTRACT(MONTH FROM h.month)
LEFT JOIN runrate AS rr ON rr.canonical_category = c.category_name
LEFT JOIN accrual_fwd AS af ON af.category_name = c.category_name
WHERE c.active AND c.category_kind = 'expense' AND c.category_name != 'Unclassified';
