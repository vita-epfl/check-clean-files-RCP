#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/rcp_scan_config.sh
source "$SCRIPT_DIR/rcp_scan_config.sh"

required_header='"Directory","Size","Modified","Accessed","Owner"'
missing=0

echo "Checking scan outputs in: $RCP_SCAN_OUTPUT_DIR"

for scope in "${RCP_SCAN_SCOPES[@]}"; do
    csv_path="${RCP_SCAN_OUTPUT_DIR}/$(rcp_scope_csv "$scope")"
    summary_path="${RCP_SCAN_OUTPUT_DIR}/$(rcp_scope_summary "$scope")"

    if [ ! -s "$csv_path" ]; then
        echo "Missing or empty CSV: $csv_path" >&2
        missing=1
        continue
    fi

    header="$(head -n 1 "$csv_path")"
    if [ "$header" != "$required_header" ]; then
        echo "Unexpected header in $csv_path: $header" >&2
        missing=1
    fi

    if [ ! -s "$summary_path" ]; then
        echo "Missing or empty summary: $summary_path" >&2
        missing=1
    fi

    rows="$(awk 'NR > 1 && NF {count++} END {print count + 0}' "$csv_path")"
    echo "  $(rcp_scope_label "$scope"): $rows CSV rows"
done

exit "$missing"
