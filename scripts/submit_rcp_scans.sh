#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/rcp_scan_config.sh
source "$SCRIPT_DIR/rcp_scan_config.sh"

execute=false
assume_yes=false

usage() {
    cat <<'EOF'
Usage: scripts/submit_rcp_scans.sh [--execute] [--yes]

Print the three Run:ai submission commands for the configured RCP scratch scan.
By default this is a dry run. With --execute, the script prints the exact
commands and asks for confirmation before submitting.

Useful environment overrides:
  RCP_SCAN_PROJECT=vita-<username>
  RCP_SCAN_RUN_DATE=YYYY-MM-DD
  RCP_SCAN_RUN_ID=YYYYMMDD-HHMMSS
  RCP_SCAN_OUTPUT_ROOT=/mnt/vita/scratch/.../check-clean-files/output
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --execute) execute=true ;;
        --yes) assume_yes=true ;;
        -h|--help) usage; exit 0 ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
    shift
done

echo "Run date: $RCP_SCAN_RUN_DATE"
echo "Run ID: $RCP_SCAN_RUN_ID"
echo "Project: $RCP_SCAN_PROJECT"
echo "Image: $RCP_SCAN_IMAGE"
echo "Output directory: $RCP_SCAN_OUTPUT_DIR"
echo
echo "Run:ai commands:"

for scope in "${RCP_SCAN_SCOPES[@]}"; do
    declare -a submit_args=()
    rcp_submit_args "$scope" submit_args
    echo
    echo "# $(rcp_scope_label "$scope") -> $(rcp_scope_csv "$scope")"
    rcp_print_command "${submit_args[@]}"
done

if [ "$execute" != true ]; then
    echo
    echo "Dry run only. Re-run with --execute to be prompted before submission."
    exit 0
fi

if ! command -v runai >/dev/null 2>&1; then
    echo "runai was not found on PATH." >&2
    exit 1
fi

if [ "$assume_yes" != true ]; then
    echo
    read -r -p "Submit these 3 Run:ai jobs? Type 'submit' to continue: " confirmation
    if [ "$confirmation" != "submit" ]; then
        echo "Submission cancelled."
        exit 0
    fi
fi

mkdir -p "$RCP_SCAN_OUTPUT_DIR"
rcp_write_manifest
echo "Wrote manifest: $(rcp_manifest_path)"

for scope in "${RCP_SCAN_SCOPES[@]}"; do
    declare -a submit_args=()
    rcp_submit_args "$scope" submit_args
    echo "Submitting $(rcp_job_name "$scope")..."
    "${submit_args[@]}"
done

echo
echo "Submitted all scan jobs. Monitor with:"
printf '  %q\n' "$SCRIPT_DIR/wait_rcp_scans.sh"
