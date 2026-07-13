#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/rcp_scan_config.sh
source "$SCRIPT_DIR/rcp_scan_config.sh"

python3 "$SCRIPT_DIR/generate_storage_report.py" "$RCP_SCAN_OUTPUT_DIR" "$@"
