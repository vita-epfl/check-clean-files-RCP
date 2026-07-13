#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/rcp_scan_config.sh
source "$SCRIPT_DIR/rcp_scan_config.sh"

python3 "$SCRIPT_DIR/generate_storage_report.py" "$RCP_SCAN_OUTPUT_DIR" --limit "${RCP_REPORT_LIMIT:-20}"
python3 "$SCRIPT_DIR/upload_storage_report_to_notion.py" \
    "$RCP_SCAN_OUTPUT_DIR/storage_report.md" \
    --parent-page-id "${NOTION_PARENT_PAGE_ID:-39c953b34421805f9b81d664f291f945}"
