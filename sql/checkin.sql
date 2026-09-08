-- Daily spend check-in state: one row per generation run.
--
-- OPERATIONAL STATE, not derived data. This table is deliberately
-- CREATE TABLE IF NOT EXISTS (the durable-table pattern shared with
-- classification_rules, manual_income, vendor_rules): deploy.sh applies this
-- file so the table self-heals on a fresh project, and a full rebuild never
-- drops it. It is NOT "safe to rebuild" — see AGENTS.md.
--
-- Invariants (enforced by scripts/checkin-write.sh, checked by the standing
-- acceptance queries in the spend-checkin skill):
--   * successful windows are contiguous and non-overlapping
--   * at most one status='success' row per window_start
--   * failed rows never advance any checkpoint
--   * append-only: no UPDATE path; recovery is BigQuery time travel
CREATE TABLE IF NOT EXISTS `__PROJECT_ID__.__FINANCE_DATASET__.checkin_reports` (
  run_ts TIMESTAMP NOT NULL,
  -- The checkpoint this run consumed (MAX(window_end) over prior successful
  -- rows at resolution time). Stored so checkpoint reproducibility is checkable.
  consumed_checkpoint TIMESTAMP,
  window_start TIMESTAMP NOT NULL,
  window_end TIMESTAMP NOT NULL,
  -- 'success' | 'failed' (a duplicate fire is a MERGE no-op, not a row)
  status STRING NOT NULL,
  fail_reason STRING,
  -- Per-source detail: {mirror|vantage|live_costs|mercury: {window_start,
  -- window_end, status, total, note}}. Per-source checkpoints resolve from
  -- the sources JSON of successful pulls, not the global window.
  sources JSON,
  -- Headline numbers: {personal_cash, mercury_cash, cloud_billed, cloud_live}.
  totals JSON,
  report_md STRING
);
