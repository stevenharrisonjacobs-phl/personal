CREATE TEMP FUNCTION parse_tiller_date(value STRING) AS (
  COALESCE(
    SAFE_CAST(value AS DATE),
    SAFE.PARSE_DATE('%m/%d/%Y', value),
    SAFE.PARSE_DATE('%m/%d/%y', value)
  )
);

CREATE OR REPLACE TABLE `__PROJECT_ID__.__FINANCE_DATASET__.transactions`
PARTITION BY transaction_date
CLUSTER BY account_id, source_category AS
WITH source AS (
  SELECT TO_JSON_STRING(source_row) AS payload
  FROM `__PROJECT_ID__.__RAW_DATASET__.transactions_external` AS source_row
), normalized AS (
  SELECT
    parse_tiller_date(JSON_VALUE(payload, '$.Date')) AS transaction_date,
    JSON_VALUE(payload, '$.Description') AS description,
    COALESCE(
      JSON_VALUE(payload, '$.Full_Description'),
      JSON_VALUE(payload, '$."Full Description"')
    ) AS full_description,
    JSON_VALUE(payload, '$.Category') AS source_category,
    SAFE_CAST(REPLACE(REPLACE(JSON_VALUE(payload, '$.Amount'), ',', ''), '$', '') AS NUMERIC) AS amount,
    JSON_VALUE(payload, '$.Account') AS account_name,
    COALESCE(
      JSON_VALUE(payload, '$.Account__'),
      JSON_VALUE(payload, '$.Account_'),
      JSON_VALUE(payload, '$."Account #"')
    ) AS account_number_masked,
    JSON_VALUE(payload, '$.Institution') AS institution,
    parse_tiller_date(JSON_VALUE(payload, '$.Month')) AS transaction_month,
    parse_tiller_date(JSON_VALUE(payload, '$.Week')) AS transaction_week,
    COALESCE(JSON_VALUE(payload, '$.Transaction_ID'), JSON_VALUE(payload, '$."Transaction ID"')) AS transaction_id,
    COALESCE(JSON_VALUE(payload, '$.Account_ID'), JSON_VALUE(payload, '$."Account ID"')) AS account_id,
    COALESCE(
      JSON_VALUE(payload, '$.Check_Number'),
      JSON_VALUE(payload, '$.Check'),
      JSON_VALUE(payload, '$."Check Number"')
    ) AS check_number,
    parse_tiller_date(COALESCE(JSON_VALUE(payload, '$.Date_Added'), JSON_VALUE(payload, '$."Date Added"'))) AS date_added,
    COALESCE(JSON_VALUE(payload, '$.Categorized_By'), JSON_VALUE(payload, '$."Categorized By"')) AS categorized_by,
    JSON_VALUE(payload, '$.Source') AS source,
    payload AS source_payload
  FROM source
), tiller_rows AS (
  SELECT
    COALESCE(
      NULLIF(transaction_id, ''),
      TO_HEX(SHA256(CONCAT(
        COALESCE(CAST(transaction_date AS STRING), ''), '|',
        COALESCE(description, ''), '|',
        COALESCE(CAST(amount AS STRING), ''), '|',
        COALESCE(account_id, account_name, '')
      )))
    ) AS transaction_key,
    *
  FROM normalized
  WHERE transaction_date IS NOT NULL
    AND amount IS NOT NULL
), tiller_coverage AS (
  SELECT
    UPPER(TRIM(account_name)) AS coverage_account,
    MIN(transaction_date) AS coverage_start,
    MAX(transaction_date) AS coverage_end
  FROM tiller_rows
  GROUP BY coverage_account
), copilot_fingerprinted AS (
  SELECT
    SAFE_CAST(c.transaction_date AS DATE) AS cop_date,
    c.name,
    SAFE_CAST(c.amount AS NUMERIC) AS cop_amount,
    c.category,
    c.account_name,
    c.account_mask,
    LOWER(TRIM(c.status)) AS status,
    LOWER(TRIM(c.transaction_type)) AS transaction_type,
    LOWER(TRIM(c.excluded)) AS excluded,
    TO_JSON_STRING(c) AS source_payload,
    TO_HEX(SHA256(TO_JSON_STRING(c))) AS fingerprint
  FROM `__PROJECT_ID__.__RAW_DATASET__.copilot_transactions` AS c
), copilot_numbered AS (
  SELECT
    *,
    ROW_NUMBER() OVER (PARTITION BY fingerprint ORDER BY fingerprint) AS source_occurrence
  FROM copilot_fingerprinted
  WHERE status = 'posted'
    AND transaction_type = 'regular'
    AND excluded = 'false'
    AND cop_date IS NOT NULL
    AND cop_amount IS NOT NULL
), copilot_netnew AS (
  SELECT
    TO_HEX(SHA256(CONCAT('copilot|', fingerprint, '#', CAST(source_occurrence AS STRING)))) AS transaction_key,
    cop_date AS transaction_date,
    name AS description,
    name AS full_description,
    category AS source_category,
    -cop_amount AS amount,
    account_name,
    account_mask AS account_number_masked,
    CAST(NULL AS STRING) AS institution,
    DATE_TRUNC(cop_date, MONTH) AS transaction_month,
    DATE_TRUNC(cop_date, WEEK) AS transaction_week,
    CAST(NULL AS STRING) AS transaction_id,
    CAST(NULL AS STRING) AS account_id,
    CAST(NULL AS STRING) AS check_number,
    cop_date AS date_added,
    'copilot' AS categorized_by,
    'copilot' AS source,
    source_payload
  FROM copilot_numbered AS c
  JOIN tiller_coverage AS cov
    ON cov.coverage_account = UPPER(TRIM(c.account_name))
   AND c.cop_date BETWEEN cov.coverage_start AND cov.coverage_end
  WHERE NOT EXISTS (
    SELECT 1
    FROM tiller_rows AS t
    WHERE t.transaction_date
            BETWEEN DATE_SUB(c.cop_date, INTERVAL 4 DAY) AND DATE_ADD(c.cop_date, INTERVAL 4 DAY)
      AND t.amount = -c.cop_amount
      AND UPPER(TRIM(t.account_name)) = UPPER(TRIM(c.account_name))
  )
)
SELECT * FROM tiller_rows
UNION ALL
SELECT * FROM copilot_netnew;

CREATE OR REPLACE TABLE `__PROJECT_ID__.__FINANCE_DATASET__.balance_history`
PARTITION BY balance_date
CLUSTER BY account_id AS
WITH source AS (
  SELECT TO_JSON_STRING(source_row) AS payload
  FROM `__PROJECT_ID__.__RAW_DATASET__.balance_history_external` AS source_row
), normalized AS (
  SELECT
    parse_tiller_date(JSON_VALUE(payload, '$.Date')) AS balance_date,
    SAFE_CAST(JSON_VALUE(payload, '$.Time') AS TIME) AS balance_time_utc,
    JSON_VALUE(payload, '$.Account') AS account_name,
    COALESCE(
      JSON_VALUE(payload, '$.Account__'),
      JSON_VALUE(payload, '$.Account_'),
      JSON_VALUE(payload, '$."Account #"')
    ) AS account_number_masked,
    JSON_VALUE(payload, '$.Institution') AS institution,
    SAFE_CAST(REPLACE(REPLACE(JSON_VALUE(payload, '$.Balance'), ',', ''), '$', '') AS NUMERIC) AS balance,
    parse_tiller_date(JSON_VALUE(payload, '$.Month')) AS balance_month,
    parse_tiller_date(JSON_VALUE(payload, '$.Week')) AS balance_week,
    COALESCE(JSON_VALUE(payload, '$.Account_ID'), JSON_VALUE(payload, '$."Account ID"')) AS account_id,
    COALESCE(JSON_VALUE(payload, '$.Balance_ID'), JSON_VALUE(payload, '$."Balance ID"')) AS balance_id,
    JSON_VALUE(payload, '$.Type') AS account_type,
    LOWER(JSON_VALUE(payload, '$.Class')) AS account_class,
    JSON_VALUE(payload, '$.Source') AS source,
    payload AS source_payload
  FROM source
)
SELECT
  COALESCE(
    NULLIF(balance_id, ''),
    TO_HEX(SHA256(CONCAT(
      COALESCE(CAST(balance_date AS STRING), ''), '|',
      COALESCE(CAST(balance_time_utc AS STRING), ''), '|',
      COALESCE(account_id, account_name, '')
    )))
  ) AS balance_key,
  *
FROM normalized
WHERE balance_date IS NOT NULL
  AND balance IS NOT NULL;
