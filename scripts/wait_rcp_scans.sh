#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/rcp_scan_config.sh
source "$SCRIPT_DIR/rcp_scan_config.sh"

poll_seconds="${RCP_SCAN_POLL_SECONDS:-120}"
timeout_seconds="${RCP_SCAN_WAIT_TIMEOUT_SECONDS:-0}"

usage() {
    cat <<'EOF'
Usage: scripts/wait_rcp_scans.sh [--poll-seconds N] [--timeout-seconds N]

Poll Run:ai until the configured datasets/staff/students jobs finish.
Set RCP_SCAN_RUN_ID to the run ID printed by submit_rcp_scans.sh when waiting
for a previous run.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --poll-seconds)
            poll_seconds="$2"
            shift
            ;;
        --timeout-seconds)
            timeout_seconds="$2"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
    shift
done

if ! command -v "$RCP_RUNAI_BIN" >/dev/null 2>&1; then
    echo "Run:ai CLI was not found: $RCP_RUNAI_BIN" >&2
    echo "Set RCP_RUNAI_BIN to the full path, or add runai to PATH." >&2
    exit 1
fi

status_for_job() {
    local job="$1"
    local raw
    raw="$("$RCP_RUNAI_BIN" training describe "$job" -p "$RCP_SCAN_PROJECT" -o json)"
    python3 - "$raw" <<'PY'
import json
import re
import sys

payload = sys.argv[1]
try:
    data = json.loads(payload)
except json.JSONDecodeError:
    match = re.search(r'\b(Completed|Failed|Stopped|Running|Pending|Initializing|Suspended)\b', payload)
    print(match.group(1) if match else "Unknown")
    raise SystemExit

def walk(value):
    if isinstance(value, dict):
        for key in ("phase", "state", "status", "workloadStatus", "workloadState"):
            if key in value and isinstance(value[key], str):
                yield value[key]
        for child in value.values():
            yield from walk(child)
    elif isinstance(value, list):
        for child in value:
            yield from walk(child)

preferred = {"Completed", "Failed", "Stopped", "Running", "Pending", "Initializing", "Suspended"}
for candidate in walk(data):
    for status in preferred:
        if candidate.lower() == status.lower():
            print(status)
            raise SystemExit
print("Unknown")
PY
}

started_at="$(date +%s)"
while true; do
    complete_count=0
    failed_count=0
    echo "Status at $(date -Is):"

    for scope in "${RCP_SCAN_SCOPES[@]}"; do
        job="$(rcp_job_name "$scope")"
        status="$(status_for_job "$job")"
        printf '  %-42s %s\n' "$job" "$status"
        case "$status" in
            Completed) complete_count=$((complete_count + 1)) ;;
            Failed|Stopped) failed_count=$((failed_count + 1)) ;;
        esac
    done

    if [ "$failed_count" -gt 0 ]; then
        echo "At least one scan job failed or stopped." >&2
        exit 1
    fi

    if [ "$complete_count" -eq "${#RCP_SCAN_SCOPES[@]}" ]; then
        echo "All scan jobs completed."
        exit 0
    fi

    if [ "$timeout_seconds" -gt 0 ]; then
        now="$(date +%s)"
        if [ $((now - started_at)) -ge "$timeout_seconds" ]; then
            echo "Timed out waiting for scan jobs." >&2
            exit 1
        fi
    fi

    sleep "$poll_seconds"
done
