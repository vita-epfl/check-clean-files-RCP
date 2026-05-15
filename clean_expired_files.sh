#!/bin/bash

set -eu

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
files_list="$SCRIPT_DIR/files_to_clean"
dry_run=false
parallelism="${CLEAN_FILES_JOBS:-1}"

print_usage() {
    cat >&2 <<'EOF'
Usage: clean_expired_files.sh [-f files_list] [-j parallelism] [--dry-run]
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        -f)
            files_list="$2"
            shift 2
            ;;
        -j)
            parallelism="$2"
            shift 2
            ;;
        --dry-run)
            dry_run=true
            shift
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

if [ ! -f "$files_list" ]; then
    echo "Error: file not found: $files_list" >&2
    exit 1
fi

echo "Using file list: $files_list" >&2
echo "Parallelism: $parallelism" >&2
echo "Dry run: $dry_run" >&2

list_paths() {
    awk '{print $1}' "$files_list" | while IFS= read -r path; do
        [ -z "$path" ] && continue
        if [ -e "$path" ]; then
            echo "$path"
        else
            echo "Skipping missing path: $path" >&2
        fi
    done
}

if [ "$dry_run" = true ]; then
    list_paths
    exit 0
fi

list_paths | xargs -I {} -P "$parallelism" bash -c 'rm -rf "$1" && echo "Deleted: $1"' _ {}
