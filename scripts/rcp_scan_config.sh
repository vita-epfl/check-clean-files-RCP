#!/usr/bin/env bash

set -uo pipefail

RCP_SCAN_IMAGE="${RCP_SCAN_IMAGE:-registry.rcp.epfl.ch/vita/check-clean-files:latest}"
RCP_SCAN_USER="${RCP_SCAN_USER:-alefevre}"
RCP_SCAN_PROJECT="${RCP_SCAN_PROJECT:-vita-${RCP_SCAN_USER}}"
RCP_SCAN_OUTPUT_ROOT="${RCP_SCAN_OUTPUT_ROOT:-/mnt/vita/scratch/vita-staff/users/alefevre/programs/check-clean-files/output}"
RCP_SCAN_RUN_DATE="${RCP_SCAN_RUN_DATE:-$(date +%F)}"
RCP_SCAN_RUN_ID="${RCP_SCAN_RUN_ID:-$(date +%Y%m%d-%H%M%S)}"
RCP_SCAN_OUTPUT_DIR="${RCP_SCAN_OUTPUT_ROOT}/runs/${RCP_SCAN_RUN_DATE}"
RCP_SCAN_CPU_CORES="${RCP_SCAN_CPU_CORES:-4}"
RCP_SCAN_MEMORY="${RCP_SCAN_MEMORY:-32G}"
RCP_SCAN_PVC_CLAIM="${RCP_SCAN_PVC_CLAIM:-vita-scratch}"
RCP_SCAN_PVC_PATH="${RCP_SCAN_PVC_PATH:-/mnt/vita/scratch}"
RCP_SCAN_JOB_PREFIX="${RCP_SCAN_JOB_PREFIX:-check-files}"
RCP_RUNAI_BIN="${RCP_RUNAI_BIN:-runai}"

RCP_SCAN_SCOPES=(datasets staff students)

rcp_scope_label() {
    case "$1" in
        datasets) printf '%s\n' "datasets" ;;
        staff) printf '%s\n' "vita-staff" ;;
        students) printf '%s\n' "vita-students" ;;
        *) return 1 ;;
    esac
}

rcp_scope_base_dir() {
    case "$1" in
        datasets) printf '%s\n' "/mnt/vita/scratch/datasets" ;;
        staff) printf '%s\n' "/mnt/vita/scratch/vita-staff/users" ;;
        students) printf '%s\n' "/mnt/vita/scratch/vita-students/users" ;;
        *) return 1 ;;
    esac
}

rcp_scope_csv() {
    case "$1" in
        datasets) printf '%s\n' "files_datasets.csv" ;;
        staff) printf '%s\n' "files_staff.csv" ;;
        students) printf '%s\n' "files_students.csv" ;;
        *) return 1 ;;
    esac
}

rcp_scope_summary() {
    local csv_name
    csv_name="$(rcp_scope_csv "$1")"
    printf '%s.summary.txt\n' "${csv_name%.*}"
}

rcp_scope_scan_args() {
    case "$1" in
        datasets) printf '%s\n' "-m 100 -d 1 --measure-mindepth 1 -t 600" ;;
        staff|students) printf '%s\n' "-m 100 -d 2 --measure-mindepth 2 -t 600" ;;
        *) return 1 ;;
    esac
}

rcp_job_name() {
    local scope="$1"
    local sanitized_run_id
    sanitized_run_id="$(printf '%s' "$RCP_SCAN_RUN_ID" | tr '[:upper:]_' '[:lower:]-' | tr -cd 'a-z0-9-')"
    printf '%s-%s-%s\n' "$RCP_SCAN_JOB_PREFIX" "$scope" "$sanitized_run_id"
}

rcp_submit_args() {
    local scope="$1"
    local out_var="$2"
    local -n args_ref="$out_var"
    local csv_name base_dir

    csv_name="$(rcp_scope_csv "$scope")"
    base_dir="$(rcp_scope_base_dir "$scope")"

    args_ref=(
        "$RCP_RUNAI_BIN" training submit "$(rcp_job_name "$scope")"
        -p "$RCP_SCAN_PROJECT"
        -i "$RCP_SCAN_IMAGE"
        --image-pull-policy Always
        --cpu-core-request "$RCP_SCAN_CPU_CORES"
        --cpu-memory-request "$RCP_SCAN_MEMORY"
        --existing-pvc "claimname=${RCP_SCAN_PVC_CLAIM},path=${RCP_SCAN_PVC_PATH}"
        --restart-policy Never
        --command -- bash /opt/check-clean-files/check_files.sh
        -b "$base_dir"
        -O "$RCP_SCAN_OUTPUT_DIR"
    )

    case "$scope" in
        datasets)
            args_ref+=(-m 100 -d 1 --measure-mindepth 1 -t 600 -o "$csv_name")
            ;;
        staff|students)
            args_ref+=(-m 100 -d 2 --measure-mindepth 2 -t 600 -o "$csv_name")
            ;;
        *)
            return 1
            ;;
    esac
}

rcp_print_command() {
    local -a args=("$@")
    printf '  '
    printf '%q ' "${args[@]}"
    printf '\n'
}

rcp_manifest_path() {
    printf '%s\n' "${RCP_SCAN_OUTPUT_DIR}/run_manifest.env"
}

rcp_write_manifest() {
    local manifest_path
    manifest_path="$(rcp_manifest_path)"
    {
        printf 'RCP_SCAN_RUN_DATE=%q\n' "$RCP_SCAN_RUN_DATE"
        printf 'RCP_SCAN_RUN_ID=%q\n' "$RCP_SCAN_RUN_ID"
        printf 'RCP_SCAN_PROJECT=%q\n' "$RCP_SCAN_PROJECT"
        printf 'RCP_SCAN_IMAGE=%q\n' "$RCP_SCAN_IMAGE"
        printf 'RCP_SCAN_OUTPUT_ROOT=%q\n' "$RCP_SCAN_OUTPUT_ROOT"
        printf 'RCP_SCAN_OUTPUT_DIR=%q\n' "$RCP_SCAN_OUTPUT_DIR"
        printf 'RCP_SCAN_SCOPES=%q\n' "${RCP_SCAN_SCOPES[*]}"
        local scope
        for scope in "${RCP_SCAN_SCOPES[@]}"; do
            printf 'RCP_SCAN_JOB_%s=%q\n' "${scope^^}" "$(rcp_job_name "$scope")"
        done
    } > "$manifest_path"
}
