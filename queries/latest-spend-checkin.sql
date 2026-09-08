-- The newest successful daily spend check-in — the morning report the
-- /spend-checkin skill serves. A failed newest run is skipped in favor of the
-- last success; its failure is visible in the report's own Notes next morning.
SELECT
  run_ts,
  window_start,
  window_end,
  totals,
  report_md
FROM `__PROJECT_ID__.__FINANCE_DATASET__.checkin_reports`
WHERE status = 'success'
ORDER BY run_ts DESC
LIMIT 1;
