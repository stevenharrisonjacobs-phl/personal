SELECT
  flow_type,
  COUNT(*) AS transaction_count,
  COUNTIF(amount < 0) AS outflows,
  COUNTIF(amount > 0) AS inflows,
  COUNTIF(amount = 0) AS zero_amounts,
  ROUND(SUM(amount), 2) AS signed_total,
  ROUND(AVG(flow_confidence), 3) AS average_confidence
FROM `__PROJECT_ID__.__GOLD_DATASET__.transactions`
GROUP BY flow_type
ORDER BY transaction_count DESC;
