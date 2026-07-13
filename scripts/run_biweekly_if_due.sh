#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/rcp_scan_config.sh
source "$SCRIPT_DIR/rcp_scan_config.sh"

stamp_file="${RCP_BIWEEKLY_STAMP_FILE:-${RCP_SCAN_OUTPUT_ROOT}/last_successful_recurring_scan.txt}"
min_interval_days="${RCP_BIWEEKLY_MIN_INTERVAL_DAYS:-13}"

now_epoch="$(date +%s)"
if [ -s "$stamp_file" ]; then
    last_epoch="$(cat "$stamp_file")"
    if [[ "$last_epoch" =~ ^[0-9]+$ ]]; then
        elapsed_days=$(( (now_epoch - last_epoch) / 86400 ))
        if [ "$elapsed_days" -lt "$min_interval_days" ]; then
            echo "Skipping recurring RCP scan; last successful run was $elapsed_days days ago."
            exit 0
        fi
    fi
fi

"$SCRIPT_DIR/run_recurring_pipeline.sh"
mkdir -p "$(dirname "$stamp_file")"
printf '%s\n' "$now_epoch" > "$stamp_file"
