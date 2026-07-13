#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/rcp_scan_config.sh
source "$SCRIPT_DIR/rcp_scan_config.sh"

execute=false
assume_yes=false
notion_secret_name="${NOTION_SECRET_NAME:-notion-api-key}"
notion_secret_key="${NOTION_SECRET_KEY:-token}"
notion_parent_page_id="${NOTION_PARENT_PAGE_ID:-39c953b34421805f9b81d664f291f945}"

usage() {
    cat <<'EOF'
Usage: scripts/submit_report_upload_job.sh [--execute] [--yes]

Submit a small Run:ai job that mounts the same scratch PVC, generates the
Markdown/JSON report for the configured run folder, and uploads the Markdown
report to Notion.

The Notion token is expected as a Kubernetes secret:
  NOTION_SECRET_NAME=notion-api-key
  NOTION_SECRET_KEY=token

Useful environment overrides:
  RCP_SCAN_RUN_DATE=YYYY-MM-DD
  RCP_SCAN_RUN_ID=YYYYMMDD-HHMMSS
  NOTION_PARENT_PAGE_ID=<page-id-or-url>
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

job_name="$(rcp_job_name report-upload)"
declare -a submit_args=(
    "$RCP_RUNAI_BIN" training submit "$job_name"
    -p "$RCP_SCAN_PROJECT"
    -i "$RCP_SCAN_IMAGE"
    --image-pull-policy Always
    --cpu-core-request 1
    --cpu-memory-request 2G
    --existing-pvc "claimname=${RCP_SCAN_PVC_CLAIM},path=${RCP_SCAN_PVC_PATH}"
    --env-secret "NOTION_API_KEY=${notion_secret_name},key=${notion_secret_key}"
    --environment-variable "RCP_SCAN_OUTPUT_ROOT=${RCP_SCAN_OUTPUT_ROOT}"
    --environment-variable "RCP_SCAN_RUN_DATE=${RCP_SCAN_RUN_DATE}"
    --environment-variable "RCP_SCAN_RUN_ID=${RCP_SCAN_RUN_ID}"
    --environment-variable "RCP_SCAN_PROJECT=${RCP_SCAN_PROJECT}"
    --environment-variable "NOTION_PARENT_PAGE_ID=${notion_parent_page_id}"
    --restart-policy Never
    --command -- bash /opt/check-clean-files/scripts/run_report_upload.sh
)

echo "Report/upload job:"
echo "Run date: $RCP_SCAN_RUN_DATE"
echo "Run ID: $RCP_SCAN_RUN_ID"
echo "Project: $RCP_SCAN_PROJECT"
echo "Image: $RCP_SCAN_IMAGE"
echo "Output directory: $RCP_SCAN_OUTPUT_DIR"
echo "Notion parent page: $notion_parent_page_id"
echo "Notion token source: secret ${notion_secret_name}, key ${notion_secret_key}"
echo
rcp_print_command "${submit_args[@]}"

if [ "$execute" != true ]; then
    echo
    echo "Dry run only. Re-run with --execute to be prompted before submission."
    exit 0
fi

if ! command -v "$RCP_RUNAI_BIN" >/dev/null 2>&1; then
    echo "Run:ai CLI was not found: $RCP_RUNAI_BIN" >&2
    echo "Set RCP_RUNAI_BIN to the full path, or add runai to PATH." >&2
    exit 1
fi

if [ "$assume_yes" != true ]; then
    echo
    read -r -p "Submit this Run:ai report/upload job? Type 'submit' to continue: " confirmation
    if [ "$confirmation" != "submit" ]; then
        echo "Submission cancelled."
        exit 0
    fi
fi

"${submit_args[@]}"
