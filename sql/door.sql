-- Personal Door write audit: one row per write ATTEMPT through the door.
--
-- OPERATIONAL STATE, not derived data. Same durable-table pattern as
-- sql/checkin.sql: CREATE TABLE IF NOT EXISTS so deploy.sh self-heals a fresh
-- project and a full rebuild never drops it. NOT safe to rebuild.
--
-- Invariants (enforced by door/finance_write.py, proven offline by
-- tests/test_door_write.py):
--   * EVERY write attempt lands one row — accepted, no-op, or refused.
--   * Accepted writes insert their audit row inside the SAME multi-statement
--     transaction as the data DML, so the two land or fail together.
--     Validation refusals never reach data DML and land a standalone row.
--   * result is enumerated — 'ok' / 'no-op' / 'refused:<reason-code>' plus
--     the affected row key. Neither args nor result ever carry read-back
--     rows, amounts, memos, or free text; digit runs are scrubbed except
--     inside 64-hex transaction keys.
--   * Append-only: nothing updates or deletes audit rows.
CREATE TABLE IF NOT EXISTS `__PROJECT_ID__.__FINANCE_DATASET__.door_audit_log` (
  ts TIMESTAMP NOT NULL,
  -- Who wrote: the verified OAuth email today; machine identities arrive with
  -- the per-identity dials (U10).
  identity STRING,
  client_id STRING,
  -- 'human' for an interactive OAuth session; the scheduled-run window state
  -- arrives with the schedule dial (U10).
  window_state STRING,
  tool STRING NOT NULL,
  -- Structured, scrubbed tool arguments: keys and enumerations only.
  args JSON,
  result STRING NOT NULL
);
