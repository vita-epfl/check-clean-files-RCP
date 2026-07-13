#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/rcp_scan_config.sh
source "$SCRIPT_DIR/rcp_scan_config.sh"

lock_dir="${RCP_RECURRING_LOCK_DIR:-/tmp/check-clean-files-rcp-recurring.lock}"
local_check="${RCP_RUN_LOCAL_OUTPUT_CHECK:-auto}"

if ! mkdir "$lock_dir" 2>/dev/null; then
    echo "Another recurring RCP scan pipeline appears to be running: $lock_dir" >&2
    exit 1
fi
trap 'rmdir "$lock_dir"' EXIT

echo "Recurring RCP storage scan"
echo "Run date: $RCP_SCAN_RUN_DATE"
echo "Run ID: $RCP_SCAN_RUN_ID"
echo "Project: $RCP_SCAN_PROJECT"
echo "Image: $RCP_SCAN_IMAGE"
echo "Output directory: $RCP_SCAN_OUTPUT_DIR"
echo "Run:ai CLI: $RCP_RUNAI_BIN"
echo

"$SCRIPT_DIR/submit_rcp_scans.sh" --execute --yes
"$SCRIPT_DIR/wait_rcp_scans.sh"

case "$local_check" in
    always)
        "$SCRIPT_DIR/check_rcp_outputs.sh"
        ;;
    never)
        echo "Skipping local output validation because RCP_RUN_LOCAL_OUTPUT_CHECK=never."
        ;;
    auto)
        if [ -d "$RCP_SCAN_OUTPUT_DIR" ]; then
            "$SCRIPT_DIR/check_rcp_outputs.sh"
        else
            echo "Skipping local output validation because $RCP_SCAN_OUTPUT_DIR is not mounted here."
            echo "The report/upload Run:ai job will validate the CSV inputs inside the mounted PVC."
        fi
        ;;
    *)
        echo "Unknown RCP_RUN_LOCAL_OUTPUT_CHECK value: $local_check" >&2
        echo "Use auto, always, or never." >&2
        exit 1
        ;;
esac

"$SCRIPT_DIR/submit_report_upload_job.sh" --execute --yes

echo
echo "Recurring RCP storage scan pipeline submitted report/upload job."
