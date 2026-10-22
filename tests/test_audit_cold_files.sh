#!/bin/bash

set -euo pipefail

if ! command -v gawk >/dev/null 2>&1; then
    echo "cold-file audit tests skipped: gawk is not installed"
    exit 0
fi

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
FIXTURE_DIR=$(mktemp -d /tmp/cold-audit-fixture.XXXXXX)
REPORT_DIR=$(mktemp -d /tmp/cold-audit-report.XXXXXX)

cleanup() {
    [[ "$FIXTURE_DIR" == /tmp/cold-audit-fixture.* ]] && rm -rf -- "$FIXTURE_DIR"
    [[ "$REPORT_DIR" == /tmp/cold-audit-report.* ]] && rm -rf -- "$REPORT_DIR"
}
trap cleanup EXIT

mkdir -p \
    "$FIXTURE_DIR/project-a/checkpoints" \
    "$FIXTURE_DIR/project-a/dataset" \
    "$FIXTURE_DIR/project-b/.cache" \
    "$FIXTURE_DIR/project-b/logs"

printf 'checkpoint\n' > "$FIXTURE_DIR/project-a/checkpoints/step-100.ckpt"
printf 'audio\n' > "$FIXTURE_DIR/project-a/dataset/source.wav"
ln "$FIXTURE_DIR/project-a/dataset/source.wav" "$FIXTURE_DIR/project-a/dataset/source-copy.wav"
printf 'cache\n' > "$FIXTURE_DIR/project-b/.cache/model.bin"
printf 'log\n' > "$FIXTURE_DIR/project-b/logs/train.log"
printf 'recent\n' > "$FIXTURE_DIR/project-b/recent.txt"

touch -a -d '2025-01-01 00:00:00 UTC' \
    "$FIXTURE_DIR/project-a/checkpoints/step-100.ckpt" \
    "$FIXTURE_DIR/project-a/dataset/source.wav" \
    "$FIXTURE_DIR/project-a/dataset/source-copy.wav" \
    "$FIXTURE_DIR/project-b/.cache/model.bin" \
    "$FIXTURE_DIR/project-b/logs/train.log"
touch -a -d '2026-10-01 00:00:00 UTC' "$FIXTURE_DIR/project-b/recent.txt"

ATIME_BEFORE=$(stat -c %X "$FIXTURE_DIR/project-a/dataset/source.wav")
"$REPO_DIR/audit_cold_files.sh" \
    -b "$FIXTURE_DIR" \
    -O "$REPORT_DIR" \
    -a '6 months ago' \
    -d 2
ATIME_AFTER=$(stat -c %X "$FIXTURE_DIR/project-a/dataset/source.wav")

[ "$ATIME_BEFORE" = "$ATIME_AFTER" ] || { echo "Regular-file atime changed" >&2; exit 1; }
[ "$(wc -l < "$REPORT_DIR/cold_files.csv")" -eq 6 ] || { echo "Unexpected cold-file count" >&2; exit 1; }
! rg -q 'recent.txt' "$REPORT_DIR/cold_files.csv" || { echo "Recent file was classified as cold" >&2; exit 1; }
rg -q 'step-100.ckpt.*MODEL_OR_CHECKPOINT.*REVIEW' "$REPORT_DIR/cold_files.csv"
rg -q 'source.wav.*AUDIO_DATA.*KEEP_OR_MIGRATE' "$REPORT_DIR/cold_files.csv"
rg -q '/\.cache/model.bin.*CACHE_OR_TEMP.*CANDIDATE_AFTER_CHECK' "$REPORT_DIR/cold_files.csv"
rg -q '/logs/train.log.*TRAINING_LOG.*CANDIDATE_AFTER_CHECK' "$REPORT_DIR/cold_files.csv"
rg -q 'Completeness: \*\*COMPLETE\*\*' "$REPORT_DIR/audit_summary.md"

echo "cold-file audit tests passed"
