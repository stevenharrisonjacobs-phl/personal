-- Work (Plum Growth) cost and payment facts.
--
-- OWN DATASET, not a prefix inside finance/gold. In BigQuery the dataset is
-- the access-control unit, so `work` can be granted to a bookkeeper without
-- exposing a single personal transaction. Same project deliberately: the door's
-- runtime service account, its per-table allowlist and its one credential all
-- live here, and KD5 ("the door holds the only finance credential") is worth
-- more than the extra isolation a separate project would buy. Moving later is
-- a dataset copy, not a rewrite.
--
-- OPERATIONAL STATE, not derived data. Same durable-table pattern as
-- finance.checkin_reports and finance.door_audit_log: CREATE TABLE IF NOT
-- EXISTS so deploy.sh self-heals a fresh project and a full rebuild never drops
-- them. NOT safe to rebuild — these are COLLECTED OBSERVATIONS. Vantage,
-- LangSmith, Apify and Mercury will not serve an arbitrary historical window
-- forever, so unlike gold.transactions a rebuild cannot reconstruct them.
--
-- TWO TABLES, NOT ONE, and the split is the accrual/cash boundary:
--   daily_costs — what work CONSUMED. A continuous accrual, per day.
--   payments    — what work actually PAID. Discrete events with their own ids.
-- A single table with a lens column would have relied on discipline to keep
-- them apart; two tables cannot be summed together by accident.

CREATE SCHEMA IF NOT EXISTS `__PROJECT_ID__.__WORK_DATASET__`
OPTIONS(description = 'Work / Plum Growth cost and payment facts. Durable collected observations — never rebuilt.');

-- What work consumed, per calendar day, per provider.
CREATE TABLE IF NOT EXISTS `__PROJECT_ID__.__WORK_DATASET__.daily_costs` (
  -- Calendar day in America/New_York, NOT the check-in's 6am->6am window.
  -- Decoupling the fact from the run that saw it means a failed morning leaves
  -- a gap a later run backfills, rather than history missing a row forever.
  cost_date DATE NOT NULL,
  -- Lowercase provider key. Matches Vantage's spelling where they overlap, so
  -- 'open_ai' not 'openai'.
  provider STRING NOT NULL,
  -- WHICH MEASURE:
  --   'billed'    — what the provider charged (Vantage). Authoritative, lags
  --                 ~1 day, and IS RESTATED as ingestion catches up, which is
  --                 why this table upserts rather than appends.
  --   'estimated' — usage the check-in computed before anyone billed it
  --                 (BigQuery scan estimate, LangSmith run costs, Apify usage).
  -- Both are kept for the same day on purpose: the difference between them is
  -- the only way to find out our estimate was wrong. They are never summed.
  lens STRING NOT NULL,
  cost_usd NUMERIC NOT NULL,
  -- 'vantage' | 'collector'. Diagnostic only, deliberately NOT part of the
  -- key: a provider that moves from estimated-by-collector to billed-by-vantage
  -- must not silently become two rows for one day.
  source STRING NOT NULL,
  -- When this observation was last written. A 'billed' row with an old
  -- observed_at may still be pre-restatement.
  observed_at TIMESTAMP NOT NULL,
  run_ts TIMESTAMP
)
PARTITION BY cost_date
CLUSTER BY provider, lens
OPTIONS(description = 'Accrued work consumption. Key (cost_date, provider, lens), MERGE-upsert — billed figures restate.');

-- What work actually paid. Cash out of the Plum Growth account, subscriptions
-- included.
CREATE TABLE IF NOT EXISTS `__PROJECT_ID__.__WORK_DATASET__.payments` (
  -- Mercury's own transaction id. Keying on it makes a re-pull of an
  -- overlapping window idempotent BY CONSTRUCTION, with no window arithmetic
  -- to get wrong.
  payment_id STRING NOT NULL,
  -- postedAt (settlement), never createdAt — Mercury's own guidance, and the
  -- arrival axis the rest of the check-in windows on. A pending authorization
  -- has no posted date and therefore cannot land here at all; its COUNT
  -- belongs in the morning report, its amount does not.
  posted_date DATE NOT NULL,
  -- Raw, exactly as Mercury reports it, so an unmapped counterparty stays
  -- recognizable rather than being normalized into something invented.
  counterparty STRING NOT NULL,
  -- Normalized key that JOINS to daily_costs.provider. NULL when the
  -- counterparty maps to no consumption provider (Webflow, Canva, ...) — a
  -- real payment with nothing to reconcile against, not a mapping failure.
  provider STRING,
  -- 'snapfix' | 'bobsled' | 'unmapped'. Never guessed; see
  -- .claude/skills/spend-checkin/context/mercury-mapping.md.
  venture STRING,
  -- Positive = money out. This table is OUTFLOWS ONLY.
  amount_usd NUMERIC NOT NULL,
  account STRING,
  observed_at TIMESTAMP NOT NULL,
  run_ts TIMESTAMP
)
PARTITION BY posted_date
CLUSTER BY counterparty
OPTIONS(description = 'Work cash out, subscriptions included. Key (payment_id), MERGE-upsert. Excludes the IO AUTOPAY settlement pair and all inflows.');

-- Reconciliation: consumed versus paid, per provider. The question neither
-- table answers alone, and the reason they share a provider key.
CREATE OR REPLACE VIEW `__PROJECT_ID__.__WORK_DATASET__.v_consumed_vs_paid` AS
WITH consumed AS (
  SELECT provider, cost_date AS d, SUM(cost_usd) AS consumed_usd
  FROM `__PROJECT_ID__.__WORK_DATASET__.daily_costs`
  WHERE lens = 'billed'
  GROUP BY provider, d
), paid AS (
  SELECT provider, posted_date AS d, SUM(amount_usd) AS paid_usd
  FROM `__PROJECT_ID__.__WORK_DATASET__.payments`
  WHERE provider IS NOT NULL
  GROUP BY provider, d
)
SELECT
  COALESCE(c.provider, p.provider) AS provider,
  COALESCE(c.d, p.d) AS activity_date,
  IFNULL(c.consumed_usd, 0) AS consumed_usd,
  IFNULL(p.paid_usd, 0) AS paid_usd
FROM consumed AS c
FULL JOIN paid AS p
  ON c.provider = p.provider AND c.d = p.d;
