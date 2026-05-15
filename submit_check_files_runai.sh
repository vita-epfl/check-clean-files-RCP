#!/bin/bash

set -eu

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
IMAGE_REPO_ROOT="/opt/check-clean-files"
SCAN_SCRIPT="$IMAGE_REPO_ROOT/check_files.sh"

image=""
job_name="check-files-${USER:-user}"
project=""
cpu="4"
memory="32G"
pvc_claim="vita-scratch"
pvc_path="/mnt/vita/scratch"
run_as_uid=""
run_as_gid=""

print_usage() {
    cat >&2 <<'EOF'
Usage: submit_check_files_runai.sh -i image [-n job_name] [-p project] [-c cpu] [-m memory]
                                   [--pvc-claim claim] [--pvc-path path]
                                   [--run-as-uid uid] [--run-as-gid gid]
                                   [-- scan_args...]

Examples:
  bash submit_check_files_runai.sh -i my-image -- -m 50 -e
  bash submit_check_files_runai.sh -i my-image -p vita -- -b /mnt/vita/scratch/vita-staff/users/$USER

The image must contain check_files.sh at /opt/check-clean-files/check_files.sh.
EOF
}

declare -a scan_args=()
while [ $# -gt 0 ]; do
    case "$1" in
        -i)
            image="$2"
            shift 2
            ;;
        -n)
            job_name="$2"
            shift 2
            ;;
        -p)
            project="$2"
            shift 2
            ;;
        -c)
            cpu="$2"
            shift 2
            ;;
        -m)
            memory="$2"
            shift 2
            ;;
        --pvc-claim)
            pvc_claim="$2"
            shift 2
            ;;
        --pvc-path)
            pvc_path="$2"
            shift 2
            ;;
        --run-as-uid)
            run_as_uid="$2"
            shift 2
            ;;
        --run-as-gid)
            run_as_gid="$2"
            shift 2
            ;;
        --)
            shift
            scan_args=("$@")
            break
            ;;
        -h|--help)
            print_usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            print_usage
            exit 1
            ;;
    esac
done

if [ -z "$image" ]; then
    echo "Missing required -i <image>" >&2
    print_usage
    exit 1
fi

declare -a runai_cmd=(runai)
if [ -n "$project" ]; then
    runai_cmd+=(-p "$project")
fi

runai_cmd+=(
    submit
    --name "$job_name"
    --image "$image"
    --cpu "$cpu"
    --memory "$memory"
    --working-dir "$IMAGE_REPO_ROOT"
)

if [ -n "$run_as_uid" ]; then
    runai_cmd+=(--run-as-uid "$run_as_uid")
fi
if [ -n "$run_as_gid" ]; then
    runai_cmd+=(--run-as-gid "$run_as_gid")
fi

runai_cmd+=(--existing-pvc "claimname=$pvc_claim,path=$pvc_path")
runai_cmd+=(--command -- bash "$SCAN_SCRIPT")
runai_cmd+=("${scan_args[@]}")

printf 'Submitting Run:ai job:\n  %q' "${runai_cmd[0]}"
for ((i = 1; i < ${#runai_cmd[@]}; i++)); do
    printf ' %q' "${runai_cmd[$i]}"
done
printf '\n' >&2

"${runai_cmd[@]}"
