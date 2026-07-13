CREATE TABLE IF NOT EXISTS `__PROJECT_ID__.__GOLD_DATASET__.epic_definitions` (
  epic_definition_id STRING NOT NULL,
  epic_name STRING NOT NULL,
  epic_type STRING NOT NULL,
  source_parent_category STRING,
  source_category STRING NOT NULL,
  split_by_year BOOL NOT NULL,
  notes STRING,
  active BOOL NOT NULL,
  created_at TIMESTAMP NOT NULL
);

-- An explicit lookup keeps generic excluded transactions (transfers, taxes,
-- subscriptions, and catch-all buckets) out of the epic model.
MERGE `__PROJECT_ID__.__GOLD_DATASET__.epic_definitions` AS target
USING UNNEST([
  STRUCT('trip_10_year_staycation' AS epic_definition_id, '10 Year Staycation' AS epic_name, 'trip' AS epic_type, 'Vacations' AS source_parent_category, '10 Yr Staycation' AS source_category, FALSE AS split_by_year),
  STRUCT('trip_annas_wedding', 'Anna’s Wedding', 'trip', 'Vacations', 'Annas wedding', FALSE),
  STRUCT('trip_crystal', 'Crystal Trip', 'trip', 'Vacations', 'Crystal Trip', FALSE),
  STRUCT('trip_deer_isle', 'Deer Isle', 'trip', 'Vacations', 'Deer Isle', FALSE),
  STRUCT('trip_florida_2024', 'Florida 2024', 'trip', 'Vacations', 'Florida 24', FALSE),
  STRUCT('trip_france_2024', 'France 2024', 'trip', 'Vacations', 'France trip 24', FALSE),
  STRUCT('trip_france_2025', 'France 2025', 'trip', 'Vacations', 'France trip ‘25', FALSE),
  STRUCT('trip_greece', 'Greece Trip', 'trip', 'Vacations', 'Greece', FALSE),
  STRUCT('trip_hannah_pburg', 'Hannah – Petersburg', 'trip', 'Vacations', 'Hannah PBurg - May', FALSE),
  STRUCT('trip_maine_2024', 'Maine 2024', 'trip', 'Vacations', 'Maine ‘24', FALSE),
  STRUCT('trip_maudes_baby_shower', 'Maude’s Baby Shower', 'trip', 'Vacations', 'Maude’s Babyshower', FALSE),
  STRUCT('trip_michigan_2025', 'Michigan 2025', 'trip', 'Vacations', 'Michigan 25', FALSE),
  STRUCT('trip_offsite', 'Offsite', 'trip', 'Vacations', 'Offsite', FALSE),
  STRUCT('trip_hannah_florida', 'Hannah – Florida', 'trip', 'Vacations', 'Vacation: Hannah Florida', FALSE),
  STRUCT('trip_matts_wedding', 'Matt’s Wedding', 'trip', 'Vacations', 'Vacation: Matt’s wedding', FALSE),
  STRUCT('trip_florida_2025', 'Florida 2025', 'trip', '', 'Florida ‘25', FALSE),

  STRUCT('home_ac_2024', 'AC Fix 2024', 'home_project', 'Home Repair', 'AC Fix ‘24', FALSE),
  STRUCT('home_basement_remodel', 'Basement Remodel', 'home_project', 'Home Repair', 'Basement Remodel', FALSE),
  STRUCT('home_bug_spraying', 'Bug Spraying', 'home_project', 'Home Repair', 'Bug spraying', FALSE),
  STRUCT('home_buy_house', 'Buy House', 'home_project', 'Home Repair', 'Buy House', FALSE),
  STRUCT('home_electrical_update', 'Electrical Update', 'home_project', 'Home Repair', 'Electrical Update', FALSE),
  STRUCT('home_bathroom_toilet', 'Fix Bathroom Toilet', 'home_project', 'Home Repair', 'Fix Bathroom Toiler', FALSE),
  STRUCT('home_fridge_repair', 'Fridge Repair', 'home_project', 'Home Repair', 'Fridge repair', FALSE),
  STRUCT('home_general', 'Home Repair', 'home_project', 'Home Repair', 'Home repair', TRUE),
  STRUCT('home_furnace', 'Furnace Repair', 'home_project', 'Home Repair', 'Home Repair: Furnace', FALSE),
  STRUCT('home_kitchen_redo', 'Kitchen Redo', 'home_project', 'Home Repair', 'Kitchen Redo', FALSE),
  STRUCT('home_leak', 'Leak Repair', 'home_project', 'Home Repair', 'Leak', FALSE),
  STRUCT('home_replace_roof', 'Replace Roof', 'home_project', 'Home Repair', 'Replace Roof', FALSE),
  STRUCT('home_washer_dryer', 'Washer and Dryer', 'home_project', 'Home Repair', 'Washer and Dryer', FALSE),
  STRUCT('home_roof_deck', 'Roof Deck', 'home_project', '', 'Roof deck', FALSE),
  STRUCT('home_garbage_disposal', 'Garbage Disposal', 'home_project', '', 'Garbage Disposal', FALSE),
  STRUCT('home_fridge', 'Fridge', 'home_project', '', 'Fridge', FALSE),

  STRUCT('celebration_ada_birthday_upper', 'Ada’s Birthday', 'celebration', 'Holiday / Presents', 'Ada’s Bday', TRUE),
  STRUCT('celebration_bruce_birthday', 'Bruce’s Birthday', 'celebration', 'Holiday / Presents', 'Bruce’s Bday', TRUE),
  STRUCT('celebration_christmas_2023', 'Christmas 2023', 'celebration', 'Holiday / Presents', 'Christmas 2013', FALSE),
  STRUCT('project_brucie_bike', 'Brucie Bike', 'project', 'Holiday / Presents', 'brucie bike', FALSE),
  STRUCT('celebration_crystal_christmas_2025', 'Crystal Christmas 2025', 'celebration', '', 'Crystal Xmas ‘25', FALSE)
]) AS seed
ON target.epic_definition_id = seed.epic_definition_id
WHEN MATCHED THEN UPDATE SET
  epic_name = seed.epic_name,
  epic_type = seed.epic_type,
  source_parent_category = NULLIF(seed.source_parent_category, ''),
  source_category = seed.source_category,
  split_by_year = seed.split_by_year,
  active = TRUE
WHEN NOT MATCHED THEN
  INSERT (
    epic_definition_id, epic_name, epic_type, source_parent_category,
    source_category, split_by_year, notes, active, created_at
  )
  VALUES (
    seed.epic_definition_id, seed.epic_name, seed.epic_type,
    NULLIF(seed.source_parent_category, ''), seed.source_category,
    seed.split_by_year, 'Seeded from excluded Copilot project/trip categories',
    TRUE, CURRENT_TIMESTAMP()
  );

-- Large purchases remain ordinary categorized transactions, not epics.
UPDATE `__PROJECT_ID__.__GOLD_DATASET__.epic_definitions`
SET active = FALSE
WHERE epic_definition_id IN (
  'purchase_airpods',
  'purchase_car',
  'purchase_car_wheels',
  'purchase_iphone',
  'purchase_rugs',
  'purchase_peloton',
  'purchase_rei',
  'purchase_litter_robot'
);

CREATE OR REPLACE VIEW `__PROJECT_ID__.__GOLD_DATASET__.epic_transactions` AS
WITH raw_source AS (
  SELECT
    c.*,
    TO_HEX(SHA256(TO_JSON_STRING(STRUCT(
      transaction_date, name, amount, status, category, parent_category,
      excluded, tags, transaction_type, account_name, account_mask, note,
      recurring
    )))) AS source_fingerprint
  FROM `__PROJECT_ID__.__RAW_DATASET__.copilot_transactions` AS c
  WHERE LOWER(TRIM(COALESCE(excluded, ''))) = 'true'
), numbered_source AS (
  SELECT
    *,
    ROW_NUMBER() OVER (
      PARTITION BY source_fingerprint
      ORDER BY source_fingerprint
    ) AS source_occurrence
  FROM raw_source
), assigned AS (
  SELECT
    TO_HEX(SHA256(CONCAT(s.source_fingerprint, '#', CAST(s.source_occurrence AS STRING)))) AS source_transaction_key,
    d.epic_definition_id,
    TO_HEX(SHA256(CONCAT(
      d.epic_definition_id,
      IF(d.split_by_year, CONCAT('#', CAST(EXTRACT(YEAR FROM SAFE_CAST(s.transaction_date AS DATE)) AS STRING)), '')
    ))) AS epic_id,
    IF(
      d.split_by_year,
      CONCAT(d.epic_name, ' ', CAST(EXTRACT(YEAR FROM SAFE_CAST(s.transaction_date AS DATE)) AS STRING)),
      d.epic_name
    ) AS epic_name,
    d.epic_type,
    SAFE_CAST(s.transaction_date AS DATE) AS transaction_date,
    s.name AS source_name,
    SAFE_CAST(s.amount AS NUMERIC) AS source_amount,
    s.account_name AS source_account_name,
    s.account_mask AS source_account_mask,
    s.category AS source_category,
    s.parent_category AS source_parent_category,
    s.note AS source_note
  FROM numbered_source AS s
  JOIN `__PROJECT_ID__.__GOLD_DATASET__.epic_definitions` AS d
    ON d.active
   AND REGEXP_REPLACE(LOWER(COALESCE(d.source_parent_category, '')), r'[^a-z0-9]+', '')
       = REGEXP_REPLACE(LOWER(COALESCE(s.parent_category, '')), r'[^a-z0-9]+', '')
   AND REGEXP_REPLACE(LOWER(d.source_category), r'[^a-z0-9]+', '')
       = REGEXP_REPLACE(LOWER(COALESCE(s.category, '')), r'[^a-z0-9]+', '')
), candidates AS (
  SELECT
    a.source_transaction_key,
    t.transaction_key,
    COUNT(*) OVER (PARTITION BY a.source_transaction_key) AS source_candidate_count,
    COUNT(*) OVER (PARTITION BY t.transaction_key) AS tiller_candidate_count
  FROM assigned AS a
  JOIN `__PROJECT_ID__.__FINANCE_DATASET__.transactions` AS t
    ON t.transaction_date = a.transaction_date
   AND ABS(t.amount) = ABS(a.source_amount)
   AND RIGHT(REGEXP_REPLACE(COALESCE(t.account_number_masked, ''), r'[^0-9]+', ''), 4)
       = RIGHT(REGEXP_REPLACE(COALESCE(a.source_account_mask, ''), r'[^0-9]+', ''), 4)
), candidate_summary AS (
  SELECT
    source_transaction_key,
    COUNT(*) AS candidate_count,
    ARRAY_AGG(
      IF(source_candidate_count = 1 AND tiller_candidate_count = 1, transaction_key, NULL)
      IGNORE NULLS LIMIT 1
    )[SAFE_OFFSET(0)] AS matched_transaction_key
  FROM candidates
  GROUP BY source_transaction_key
)
SELECT
  a.source_transaction_key,
  a.epic_id,
  a.epic_name,
  a.epic_type,
  a.epic_definition_id,
  a.transaction_date,
  a.source_name,
  a.source_amount,
  a.source_account_name,
  a.source_account_mask,
  a.source_category,
  a.source_parent_category,
  a.source_note,
  c.matched_transaction_key AS transaction_key,
  CASE
    WHEN c.matched_transaction_key IS NOT NULL THEN 'matched'
    WHEN COALESCE(c.candidate_count, 0) > 0 THEN 'ambiguous'
    ELSE 'unmatched'
  END AS match_status,
  CASE WHEN c.matched_transaction_key IS NOT NULL THEN 1.00 ELSE 0.00 END AS match_confidence,
  COALESCE(c.candidate_count, 0) AS candidate_count,
  'copilot' AS source_system
FROM assigned AS a
LEFT JOIN candidate_summary AS c USING (source_transaction_key);

CREATE OR REPLACE VIEW `__PROJECT_ID__.__GOLD_DATASET__.epics` AS
SELECT
  epic_id,
  ANY_VALUE(epic_name) AS epic_name,
  ANY_VALUE(epic_type) AS epic_type,
  MIN(transaction_date) AS start_date,
  MAX(transaction_date) AS end_date,
  CASE
    WHEN MAX(transaction_date) >= DATE_SUB(CURRENT_DATE(), INTERVAL 30 DAY) THEN 'active'
    ELSE 'completed'
  END AS inferred_status,
  COUNT(*) AS transaction_count,
  COUNTIF(match_status = 'matched') AS linked_transaction_count,
  COUNTIF(match_status != 'matched') AS unlinked_transaction_count,
  ROUND(SUM(GREATEST(source_amount, 0)), 2) AS gross_spend,
  ROUND(SUM(LEAST(source_amount, 0)), 2) AS refunds_and_credits,
  ROUND(SUM(source_amount), 2) AS net_spend,
  ARRAY_AGG(DISTINCT source_category ORDER BY source_category) AS source_categories,
  'copilot' AS source_system
FROM `__PROJECT_ID__.__GOLD_DATASET__.epic_transactions`
GROUP BY epic_id;
