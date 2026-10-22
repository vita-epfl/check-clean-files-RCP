#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BASE_DIR=""
OUTPUT_DIR=""
AGE_SPEC="6 months ago"
GROUP_DEPTH=2

usage() {
    cat >&2 <<'EOF'
Usage: audit_cold_files.sh -b BASE_DIR [-O OUTPUT_DIR] [-a AGE_SPEC] [-d GROUP_DEPTH]

Create a metadata-only inventory of regular files whose access time predates the
cutoff. File contents are never opened and no deletion is performed.

Options:
  -b BASE_DIR      Volume or directory to audit (required).
  -O OUTPUT_DIR    Report directory. Default: output/cold-audit-YYYY-MM-DD.
  -a AGE_SPEC      GNU date cutoff expression. Default: "6 months ago".
  -d GROUP_DEPTH   Relative path components used to group files. Default: 2.
  -h, --help       Show this help.

Examples:
  audit_cold_files.sh -b /mnt/vita-vldriving/scratch
  audit_cold_files.sh -b /data -a "180 days ago" -d 3 -O /reports/audit
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        -b)
            [ "$#" -ge 2 ] || { echo "Missing value for -b" >&2; exit 2; }
            BASE_DIR=$2
            shift 2
            ;;
        -O)
            [ "$#" -ge 2 ] || { echo "Missing value for -O" >&2; exit 2; }
            OUTPUT_DIR=$2
            shift 2
            ;;
        -a)
            [ "$#" -ge 2 ] || { echo "Missing value for -a" >&2; exit 2; }
            AGE_SPEC=$2
            shift 2
            ;;
        -d)
            [ "$#" -ge 2 ] || { echo "Missing value for -d" >&2; exit 2; }
            GROUP_DEPTH=$2
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage
            exit 2
            ;;
    esac
done

[ -n "$BASE_DIR" ] || { echo "-b BASE_DIR is required" >&2; usage; exit 2; }
[[ "$GROUP_DEPTH" =~ ^[1-9][0-9]*$ ]] || { echo "GROUP_DEPTH must be a positive integer" >&2; exit 2; }
[ -d "$BASE_DIR" ] || { echo "Cannot access directory: $BASE_DIR" >&2; exit 1; }
command -v gawk >/dev/null 2>&1 || { echo "gawk is required (it is installed in the Docker image)" >&2; exit 1; }

BASE_DIR=${BASE_DIR%/}
if [ -z "$OUTPUT_DIR" ]; then
    OUTPUT_DIR="$SCRIPT_DIR/output/cold-audit-$(date -u +%F)"
fi
mkdir -p "$OUTPUT_DIR"

SCAN_EPOCH=$(date -u +%s)
CUTOFF_EPOCH=$(date -u -d "$AGE_SPEC" +%s) || {
    echo "Invalid cutoff expression: $AGE_SPEC" >&2
    exit 2
}
[ "$CUTOFF_EPOCH" -lt "$SCAN_EPOCH" ] || { echo "Cutoff must be in the past" >&2; exit 2; }

COLD_CSV="$OUTPUT_DIR/cold_files.csv"
DIRECTORY_RAW="$OUTPUT_DIR/.cold_by_directory.raw.tsv"
EXTENSION_RAW="$OUTPUT_DIR/.cold_by_extension.raw.tsv"
CLASS_RAW="$OUTPUT_DIR/.cold_by_class.raw.tsv"
STATS_FILE="$OUTPUT_DIR/.audit_stats.tsv"
ERROR_LOG="$OUTPUT_DIR/find_errors.log"

printf '%s\n' '"Path","LogicalBytes","AllocatedBytes","CountedAllocatedBytes","AccessedUTC","ModifiedUTC","Owner","AgeDays","Class","Suggestion","Reason","Decision"' > "$COLD_CSV"
: > "$DIRECTORY_RAW"
: > "$EXTENSION_RAW"
: > "$CLASS_RAW"
: > "$ERROR_LOG"

echo "Metadata-only scan of $BASE_DIR" >&2
echo "Cold-file cutoff: $(date -u -d "@$CUTOFF_EPOCH" '+%Y-%m-%dT%H:%M:%SZ') ($AGE_SPEC)" >&2
echo "The scanner does not open file contents and does not delete anything." >&2

set +e
find "$BASE_DIR" -xdev \
    -path "$BASE_DIR/.snapshot" -prune -o \
    -type f \
    -printf '%A@\0%T@\0%s\0%b\0%D\0%i\0%u\0%p\0' \
    2>"$ERROR_LOG" \
    | gawk \
        -v base_dir="$BASE_DIR" \
        -v cutoff_epoch="$CUTOFF_EPOCH" \
        -v scan_epoch="$SCAN_EPOCH" \
        -v group_depth="$GROUP_DEPTH" \
        -v cold_csv="$COLD_CSV" \
        -v directory_raw="$DIRECTORY_RAW" \
        -v extension_raw="$EXTENSION_RAW" \
        -v class_raw="$CLASS_RAW" \
        -v stats_file="$STATS_FILE" \
        -f "$SCRIPT_DIR/cold_file_inventory.awk"
PIPELINE_STATUS=("${PIPESTATUS[@]}")
set -e
FIND_STATUS=${PIPELINE_STATUS[0]}
GAWK_STATUS=${PIPELINE_STATUS[1]}
[ "$GAWK_STATUS" -eq 0 ] || { echo "Metadata aggregation failed with status $GAWK_STATUS" >&2; exit "$GAWK_STATUS"; }

tsv_to_directory_csv() {
    printf '%s\n' '"Directory","ColdAllocatedBytes","ColdLogicalBytes","ColdFiles","TotalFiles","ColdPercent","OldestAccessUTC","NewestAccessUTC","Decision"'
    sort -t $'\t' -k1,1nr "$DIRECTORY_RAW" | gawk -F '\t' '
        function csv(value, escaped) { escaped=value; gsub(/"/, "\"\"", escaped); return "\"" escaped "\"" }
        {
            percent = ($4 > 0) ? (100 * $3 / $4) : 0
            print csv($7) "," $1 "," $2 "," $3 "," $4 "," sprintf("%.2f", percent) "," csv($5) "," csv($6) ",\"\""
        }'
}

tsv_to_simple_csv() {
    local input_file=$1
    local label=$2
    printf '"%s","ColdAllocatedBytes","ColdLogicalBytes","ColdFiles"\n' "$label"
    sort -t $'\t' -k1,1nr "$input_file" | gawk -F '\t' '
        function csv(value, escaped) { escaped=value; gsub(/"/, "\"\"", escaped); return "\"" escaped "\"" }
        { print csv($4) "," $1 "," $2 "," $3 }'
}

tsv_to_directory_csv > "$OUTPUT_DIR/cold_by_directory.csv"
tsv_to_simple_csv "$EXTENSION_RAW" Extension > "$OUTPUT_DIR/cold_by_extension.csv"
tsv_to_simple_csv "$CLASS_RAW" Class > "$OUTPUT_DIR/cold_by_class.csv"

stat_value() {
    gawk -F '\t' -v key="$1" '$1 == key { print $2; exit }' "$STATS_FILE"
}

human_bytes() {
    numfmt --to=iec-i --suffix=B "${1:-0}"
}

TOTAL_FILES=$(stat_value total_files)
COLD_FILES=$(stat_value cold_files)
TOTAL_LOGICAL=$(stat_value total_logical_bytes)
TOTAL_ALLOCATED=$(stat_value total_allocated_bytes)
COLD_LOGICAL=$(stat_value cold_logical_bytes)
COLD_ALLOCATED=$(stat_value cold_allocated_bytes)
SCAN_ISO=$(date -u -d "@$SCAN_EPOCH" '+%Y-%m-%dT%H:%M:%SZ')
CUTOFF_ISO=$(date -u -d "@$CUTOFF_EPOCH" '+%Y-%m-%dT%H:%M:%SZ')
ERROR_COUNT=$(wc -l < "$ERROR_LOG")
COMPLETENESS=COMPLETE
if [ "$FIND_STATUS" -ne 0 ] || [ "$ERROR_COUNT" -ne 0 ]; then
    COMPLETENESS=INCOMPLETE
fi

{
    printf '# Cold-file audit\n\n'
    printf -- '- Base directory: `%s`\n' "$BASE_DIR"
    printf -- '- Scan time: %s\n' "$SCAN_ISO"
    printf -- '- Cold cutoff: access strictly before %s (%s)\n' "$CUTOFF_ISO" "$AGE_SPEC"
    printf -- '- Regular files seen: %s\n' "$TOTAL_FILES"
    printf -- '- Cold regular files: %s\n' "$COLD_FILES"
    printf -- '- Cold logical size: %s\n' "$(human_bytes "$COLD_LOGICAL")"
    printf -- '- Cold allocated size (hard links counted once): %s\n' "$(human_bytes "$COLD_ALLOCATED")"
    printf -- '- Total logical size: %s\n' "$(human_bytes "$TOTAL_LOGICAL")"
    printf -- '- Total allocated size (hard links counted once): %s\n' "$(human_bytes "$TOTAL_ALLOCATED")"
    printf -- '- Traversal errors: %s (see `find_errors.log`)\n\n' "$ERROR_COUNT"
    printf -- '- Completeness: **%s**\n\n' "$COMPLETENESS"
    printf '## Interpretation\n\n'
    printf '%s\n' '- `CANDIDATE_AFTER_CHECK`: cache, temporary data, or logs; confirm reproducibility and that no job uses them.'
    printf '%s\n' '- `REVIEW`: outputs, checkpoints, archives, or unknown data; a human decision is required.'
    printf '%s\n\n' '- `KEEP_OR_MIGRATE`: datasets, audio, code, configs, and metadata; never delete based on age alone.'
    printf 'No file content was opened and no file was deleted. Metadata traversal can update directory access times on a `relatime` mount; regular-file access times are not updated by `stat(2)`.\n\n'
    printf '## Largest cold directory groups\n\n'
    printf '| Directory | Allocated | Logical | Cold files | Total files | Cold %% | Newest cold access |\n'
    printf '| --- | ---: | ---: | ---: | ---: | ---: | --- |\n'
    sort -t $'\t' -k1,1nr "$DIRECTORY_RAW" | head -n 30 | while IFS=$'\t' read -r allocated logical cold total oldest newest directory; do
        percent=$(gawk -v cold="$cold" -v total="$total" 'BEGIN { printf "%.2f", (total ? 100*cold/total : 0) }')
        directory=${directory//|/\\|}
        printf '| `%s` | %s | %s | %s | %s | %s | %s |\n' \
            "$directory" "$(human_bytes "$allocated")" "$(human_bytes "$logical")" \
            "$cold" "$total" "$percent" "$newest"
    done
} > "$OUTPUT_DIR/audit_summary.md"

rm -f "$DIRECTORY_RAW" "$EXTENSION_RAW" "$CLASS_RAW" "$STATS_FILE"

echo "Audit complete: $OUTPUT_DIR/audit_summary.md" >&2
echo "Per-file decisions: $COLD_CSV" >&2
if [ "$COMPLETENESS" != COMPLETE ]; then
    echo "WARNING: the audit is incomplete; inspect $ERROR_LOG" >&2
    exit 3
fi
