CREATE TABLE IF NOT EXISTS `__PROJECT_ID__.__GOLD_DATASET__.transaction_onboarding_reviews` (
  transaction_key STRING NOT NULL,
  review_version STRING NOT NULL,
  transaction_date DATE NOT NULL,
  reviewed_at TIMESTAMP NOT NULL,
  review_method STRING NOT NULL,
  deterministic_flags ARRAY<STRING>,
  is_anomaly BOOL NOT NULL,
  severity STRING NOT NULL,
  anomaly_types ARRAY<STRING>,
  rationale STRING NOT NULL,
  suggested_flow_type STRING,
  suggested_category_id STRING,
  suggested_vendor_name STRING,
  requires_human_review BOOL NOT NULL,
  model STRING,
  response_id STRING,
  prompt_version STRING NOT NULL
)
CLUSTER BY review_version, requires_human_review, severity;

CREATE TABLE IF NOT EXISTS `__PROJECT_ID__.__GOLD_DATASET__.transaction_onboarding_runs` (
  run_id STRING NOT NULL,
  review_version STRING NOT NULL,
  started_at TIMESTAMP NOT NULL,
  completed_at TIMESTAMP,
  status STRING NOT NULL,
  discovered_transaction_count INT64 NOT NULL,
  deterministic_clear_count INT64 NOT NULL,
  ai_candidate_count INT64 NOT NULL,
  ai_reviewed_count INT64 NOT NULL,
  human_review_count INT64 NOT NULL,
  error_message STRING,
  model STRING
)
PARTITION BY DATE(started_at)
CLUSTER BY status, review_version;

CREATE OR REPLACE VIEW `__PROJECT_ID__.__GOLD_DATASET__.transaction_onboarding_latest` AS
SELECT * EXCEPT(review_rank)
FROM (
  SELECT
    r.*,
    ROW_NUMBER() OVER (
      PARTITION BY transaction_key
      ORDER BY reviewed_at DESC, review_version DESC
    ) AS review_rank
  FROM `__PROJECT_ID__.__GOLD_DATASET__.transaction_onboarding_reviews` AS r
)
WHERE review_rank = 1;

CREATE OR REPLACE VIEW `__PROJECT_ID__.__GOLD_DATASET__.transaction_anomaly_review_queue` AS
SELECT
  r.transaction_key,
  t.transaction_date,
  t.vendor_name,
  t.amount,
  t.flow_type,
  t.flow_confidence,
  t.canonical_category,
  r.deterministic_flags,
  r.is_anomaly,
  r.severity,
  r.anomaly_types,
  r.rationale,
  r.suggested_flow_type,
  r.suggested_category_id,
  r.suggested_vendor_name,
  r.reviewed_at,
  r.model,
  r.review_version
FROM `__PROJECT_ID__.__GOLD_DATASET__.transaction_onboarding_latest` AS r
JOIN `__PROJECT_ID__.__GOLD_DATASET__.transactions` AS t USING (transaction_key)
WHERE r.requires_human_review;

-- Backward-compatible name for clients created before session-based review.
CREATE OR REPLACE VIEW `__PROJECT_ID__.__GOLD_DATASET__.ai_anomaly_review_queue` AS
SELECT *
FROM `__PROJECT_ID__.__GOLD_DATASET__.transaction_anomaly_review_queue`;
