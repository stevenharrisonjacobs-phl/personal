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
)
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
  AND amount IS NOT NULL;

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
