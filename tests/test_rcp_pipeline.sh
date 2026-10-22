#!/usr/bin/env bash

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d /tmp/check-clean-files-rcp-test.XXXXXX)"

cleanup() {
    [[ "$TEST_DIR" == /tmp/check-clean-files-rcp-test.* ]] && rm -rf -- "$TEST_DIR"
}
trap cleanup EXIT

dry_run="$TEST_DIR/dry-run.txt"
RCP_SCAN_RUN_DATE=2026-10-22 \
RCP_SCAN_RUN_ID=test-run \
    "$REPO_DIR/scripts/submit_rcp_scans.sh" > "$dry_run"

grep -q -- '--cpu-core-request 1' "$dry_run"
grep -q -- '--cpu-core-limit 1' "$dry_run"
grep -q -- '--cpu-memory-request 4G' "$dry_run"
grep -q -- '--cpu-memory-limit 4G' "$dry_run"
grep -q -- '--node-pools v100' "$dry_run"
grep -q -- '-m 50' "$dry_run"

fake_runai="$TEST_DIR/runai"
cat > "$fake_runai" <<'EOF'
#!/usr/bin/env bash
echo "Error: Authentication failed. the token has expired" >&2
echo "Log in by running 'runai login'" >&2
exit 1
EOF
chmod +x "$fake_runai"

wait_log="$TEST_DIR/wait.log"
if RCP_RUNAI_BIN="$fake_runai" \
    RCP_SCAN_RUN_ID=test-run \
    "$REPO_DIR/scripts/wait_rcp_scans.sh" --poll-seconds 0 --job test-job \
    > "$wait_log" 2>&1; then
    echo "wait_rcp_scans.sh unexpectedly accepted an authentication failure" >&2
    exit 1
fi

grep -q 'token has expired' "$wait_log"
grep -q 'Authenticate interactively' "$wait_log"
! grep -q 'Unknown' "$wait_log"

run_dir="$TEST_DIR/runs/2026-10-22"
mkdir -p "$run_dir"
for scope in datasets staff students; do
    printf '%s\n' \
        '"Directory","Size","Modified","Accessed","Owner","Deleted"' \
        '"/example/project","50 GiB","2026-01-01","2026-01-01","owner","false"' \
        > "$run_dir/files_${scope}.csv"
    printf 'summary\n' > "$run_dir/files_${scope}.summary.txt"
done
python3 "$REPO_DIR/scripts/generate_storage_report.py" "$run_dir"
grep -q 'Vita Staff' "$run_dir/storage_report.md"
grep -q '"entries": 1' "$run_dir/storage_report.json"

echo "RCP pipeline tests passed"
