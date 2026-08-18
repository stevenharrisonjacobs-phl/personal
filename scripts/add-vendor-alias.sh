#!/usr/bin/env bash
# add-vendor-alias.sh — collapse a descriptor variant onto a canonical merchant.
#
# An alias is the right tool when the SAME merchant arrives under several
# descriptors ("Shake Shack Pa", "Shake Shack 3ridgefield Nj"). Collapse them and
# the variant inherits whatever decision the canonical name already has — do not
# write a second vendor_category_map row for it.
#
#   ./scripts/add-vendor-alias.sh "Shake Shack Pa" "Shake Shack" "descriptor variant"
#   ./scripts/add-vendor-alias.sh --batch aliases.tsv
#
# Batch format: one "alias<TAB>canonical<TAB>optional notes" per line; blank
# lines and lines starting with # are skipped.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"
load_env
require_commands bq python3

TABLE="\`${GCP_PROJECT_ID}.${GOLD_DATASET}.vendor_aliases\`"

usage() {
  sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
}

upsert_one() { # upsert_one ALIAS CANONICAL NOTES
  bq --project_id="$GCP_PROJECT_ID" --location="$BQ_LOCATION" query \
    --use_legacy_sql=false --quiet \
    --parameter="alias_name:STRING:$1" \
    --parameter="canonical_vendor_name:STRING:$2" \
    --parameter="notes:STRING:${3:-}" \
    "DECLARE normalized_alias_key STRING DEFAULT REGEXP_REPLACE(LOWER(@alias_name), r'[^a-z0-9]+', '');
     DELETE FROM $TABLE WHERE alias_key = normalized_alias_key;
     INSERT INTO $TABLE
       (alias_key, alias_name, canonical_vendor_name, notes, enabled, created_at)
     VALUES
       (normalized_alias_key, @alias_name, @canonical_vendor_name, NULLIF(@notes, ''), TRUE, CURRENT_TIMESTAMP());" \
    >/dev/null
}

# The whole batch in ONE BigQuery job, for the same reason add-vendor-category.sh
# does: every bq job costs several seconds of scheduling latency regardless of
# size, and a review session collapses variants dozens at a time (45 in one
# sitting on 2026-08-17). Rows travel as an ARRAY<STRUCT> parameter rather than
# interpolated SQL, so an apostrophe or ampersand in a merchant name cannot break
# the statement.
upsert_batch() { # upsert_batch TSV_FILE
  local rows_json
  rows_json="$(python3 - "$1" <<'PY'
import csv, json, sys
rows = []
with open(sys.argv[1], newline='') as fh:
    for rec in csv.reader(fh, delimiter='\t', quoting=csv.QUOTE_NONE):
        if not rec or not rec[0].strip() or rec[0].lstrip().startswith('#'):
            continue
        if len(rec) < 2 or not rec[1].strip():
            sys.exit(f"line missing a canonical name: {rec[0]!r}")
        rows.append({
            "alias_name":            rec[0],
            "canonical_vendor_name": rec[1],
            "notes":                 rec[2] if len(rec) > 2 else "",
        })
print(json.dumps(rows))
PY
)"

  bq --project_id="$GCP_PROJECT_ID" --location="$BQ_LOCATION" query \
    --use_legacy_sql=false --quiet \
    --parameter="rows:ARRAY<STRUCT<alias_name STRING,canonical_vendor_name STRING,notes STRING>>:$rows_json" \
    "MERGE $TABLE AS t
     USING (
       -- alias_key is the normalized form, so two different descriptors can
       -- collapse to the same key. Last occurrence wins; without this the MERGE
       -- aborts, since BigQuery refuses two source rows for one target row.
       SELECT * EXCEPT(rn) FROM (
         SELECT
           REGEXP_REPLACE(LOWER(r.alias_name), r'[^a-z0-9]+', '') AS alias_key,
           r.alias_name,
           r.canonical_vendor_name,
           r.notes,
           ROW_NUMBER() OVER (
             PARTITION BY REGEXP_REPLACE(LOWER(r.alias_name), r'[^a-z0-9]+', '')
             ORDER BY off DESC
           ) AS rn
         FROM UNNEST(@rows) AS r WITH OFFSET off
       ) WHERE rn = 1
     ) AS s
     ON t.alias_key = s.alias_key
     WHEN MATCHED THEN UPDATE SET
       alias_name            = s.alias_name,
       canonical_vendor_name = s.canonical_vendor_name,
       notes                 = NULLIF(s.notes, ''),
       enabled               = TRUE
     WHEN NOT MATCHED THEN INSERT
       (alias_key, alias_name, canonical_vendor_name, notes, enabled, created_at)
       VALUES (s.alias_key, s.alias_name, s.canonical_vendor_name,
               NULLIF(s.notes, ''), TRUE, CURRENT_TIMESTAMP());" \
    >/dev/null
}

[[ $# -ge 1 ]] || usage

if [[ "$1" == "--batch" ]]; then
  [[ $# -eq 2 && -f "$2" ]] || usage
  applied=0
  while IFS=$'\t' read -r a c notes || [[ -n "$a" ]]; do
    [[ -z "$a" || "$a" == \#* ]] && continue
    applied=$((applied + 1))
    printf '  %-42s -> %s\n' "$a" "$c"
  done < "$2"
  upsert_batch "$2"
  echo "Aliased $applied merchant(s) in one job."
else
  [[ $# -ge 2 && $# -le 3 ]] || usage
  upsert_one "$1" "$2" "${3:-}"
  echo "Aliased $1 -> $2"
fi

cat <<'EOF'

Takes effect on the next rebuild of gold.transactions — the hourly job, or
./scripts/deploy.sh now.
EOF
