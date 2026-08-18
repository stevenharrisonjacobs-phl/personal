#!/usr/bin/env bash
# add-vendor-category.sh — map a merchant to a canonical category.
#
# This is the "known classifications" table: the FIRST thing consulted for a
# category, ahead of the regex rules, which exist for merchants never seen
# before. Tiller's own category is not consulted at all.
#
#   ./scripts/add-vendor-category.sh "Giant Heirloom" groceries "grocery store"
#   ./scripts/add-vendor-category.sh --batch mappings.tsv
#
# Batch format: one "vendor<TAB>category_id<TAB>optional notes" per line;
# blank lines and lines starting with # are skipped.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"
load_env
require_commands bq python3

TABLE="\`${GCP_PROJECT_ID}.${GOLD_DATASET}.vendor_category_map\`"
CATEGORIES="\`${GCP_PROJECT_ID}.${GOLD_DATASET}.categories\`"

usage() {
  sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
}

# A typo'd category_id would insert a row that silently classifies nothing —
# the join simply finds no category and the merchant stays uncategorized. So
# validate against the live typology before writing anything.
valid_ids() {
  bq --project_id="$GCP_PROJECT_ID" --location="$BQ_LOCATION" query \
    --use_legacy_sql=false --format=csv --quiet \
    "SELECT category_id FROM $CATEGORIES WHERE active ORDER BY category_id" \
    | tail -n +2
}

upsert() { # upsert VENDOR CATEGORY_ID NOTES
  bq --project_id="$GCP_PROJECT_ID" --location="$BQ_LOCATION" query \
    --use_legacy_sql=false --quiet \
    --parameter="vendor_name:STRING:$1" \
    --parameter="category_id:STRING:$2" \
    --parameter="notes:STRING:${3:-}" \
    "DELETE FROM $TABLE WHERE vendor_name = @vendor_name;
     INSERT INTO $TABLE (vendor_name, category_id, notes, enabled, created_at)
     VALUES (@vendor_name, @category_id, NULLIF(@notes, ''), TRUE, CURRENT_TIMESTAMP());" \
    >/dev/null
}

# The whole batch in ONE BigQuery job.
#
# This used to loop `upsert` per row. Every bq job carries a few seconds of fixed
# scheduling latency no matter how small the write, so a 600-row session spent
# ~30 minutes of pure round-trip. It is also not atomic: a failure halfway leaves
# a half-applied batch, which the validate-first check exists to avoid.
#
# Rows travel as a single ARRAY<STRUCT> query parameter rather than interpolated
# SQL, so a merchant named "Dunkin'" or "Chickies & Petes" cannot break — or
# rewrite — the statement. Python builds the JSON because it escapes correctly.
upsert_batch() { # upsert_batch TSV_FILE
  local rows_json
  rows_json="$(python3 - "$1" <<'PY'
import csv, json, sys
rows = []
with open(sys.argv[1], newline='') as fh:
    for rec in csv.reader(fh, delimiter='\t', quoting=csv.QUOTE_NONE):
        if not rec or not rec[0].strip() or rec[0].lstrip().startswith('#'):
            continue
        rows.append({
            "vendor_name": rec[0],
            "category_id": rec[1] if len(rec) > 1 else "",
            "notes":       rec[2] if len(rec) > 2 else "",
        })
print(json.dumps(rows))
PY
)"

  bq --project_id="$GCP_PROJECT_ID" --location="$BQ_LOCATION" query \
    --use_legacy_sql=false --quiet \
    --parameter="rows:ARRAY<STRUCT<vendor_name STRING,category_id STRING,notes STRING>>:$rows_json" \
    "MERGE $TABLE AS t
     USING (
       -- Last occurrence wins, matching the old loop. Without this a file that
       -- names the same merchant twice aborts the MERGE: BigQuery refuses to
       -- update one target row from two source rows.
       SELECT * EXCEPT(rn) FROM (
         SELECT r.*, ROW_NUMBER() OVER (PARTITION BY r.vendor_name ORDER BY off DESC) AS rn
         FROM UNNEST(@rows) AS r WITH OFFSET off
       ) WHERE rn = 1
     ) AS s
     ON t.vendor_name = s.vendor_name
     WHEN MATCHED THEN UPDATE SET
       category_id = s.category_id,
       notes       = NULLIF(s.notes, ''),
       enabled     = TRUE
     WHEN NOT MATCHED THEN INSERT (vendor_name, category_id, notes, enabled, created_at)
       VALUES (s.vendor_name, s.category_id, NULLIF(s.notes, ''), TRUE, CURRENT_TIMESTAMP());" \
    >/dev/null
}

[[ $# -ge 1 ]] || usage

mapfile -t VALID < <(valid_ids)
is_valid() {
  local want="$1" id
  for id in "${VALID[@]}"; do [[ "$id" == "$want" ]] && return 0; done
  return 1
}

if [[ "$1" == "--batch" ]]; then
  [[ $# -eq 2 && -f "$2" ]] || usage
  # Validate the WHOLE file before writing a single row: a half-applied batch is
  # worse than a rejected one, because you cannot tell where it stopped.
  bad=0 n=0
  while IFS=$'\t' read -r vendor category notes || [[ -n "$vendor" ]]; do
    [[ -z "$vendor" || "$vendor" == \#* ]] && continue
    n=$((n + 1))
    if ! is_valid "$category"; then
      echo "line $n: unknown category_id '$category' for '$vendor'" >&2
      bad=$((bad + 1))
    fi
  done < "$2"
  if (( bad > 0 )); then
    echo "$bad invalid category_id(s). Nothing written." >&2
    echo "Valid ids: ${VALID[*]}" >&2
    exit 1
  fi

  applied=0
  while IFS=$'\t' read -r vendor category notes || [[ -n "$vendor" ]]; do
    [[ -z "$vendor" || "$vendor" == \#* ]] && continue
    applied=$((applied + 1))
    printf '  %-40s -> %s\n' "$vendor" "$category"
  done < "$2"
  upsert_batch "$2"
  echo "Mapped $applied merchant(s) in one job."
else
  [[ $# -ge 2 && $# -le 3 ]] || usage
  if ! is_valid "$2"; then
    echo "Unknown category_id: $2" >&2
    echo "Valid ids: ${VALID[*]}" >&2
    exit 1
  fi
  upsert "$1" "$2" "${3:-}"
  echo "Mapped $1 -> $2"
fi

cat <<'EOF'

Takes effect on the next rebuild of gold.transactions — the hourly job, or
./scripts/deploy.sh now.
EOF
