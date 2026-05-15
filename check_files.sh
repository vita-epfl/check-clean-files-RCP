#!/bin/bash

set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
OUTPUT_DIR="${CHECK_FILES_OUTPUT_DIR:-}"

expired_only=false
min_size_gb=50
timeout_seconds=1200
resume=false
summary_only=false
summary_limit=10
expiration_days=365
max_depth=2
measure_min_depth=1
log_basename="expired_files_rcp.csv"
declare -a base_dirs=()
declare -a user_base_dirs=()
declare -a excluded_dirs=()

print_usage() {
    cat >&2 <<'EOF'
Usage: check_files.sh [--resume] [--summary-only] [-e] [-m min_size_gb] [-t timeout_seconds]
                      [-d max_depth] [-a expiration_days] [-b base_dir[,base_dir...]]
                      [-x exclude_dir[,exclude_dir...]] [-o output_csv_basename]
                      [-O output_directory] [--measure-mindepth depth]

Options:
  -e                         Only consider directories older than expiration_days.
  -m <min_size_gb>           Minimum directory size in GB to record. Default: 50.
  -t <timeout_seconds>       Timeout for each du call. Default: 1200.
  -d <max_depth>             Maximum directory depth to scan from each base dir. Default: 2.
  --measure-mindepth <depth> Only measure directories at least this deep from each base dir. Default: 1.
  -a <expiration_days>       Age threshold for -e. Default: 365.
  -b <dir[,dir,...]>         Base directories to scan.
  -x <dir[,dir,...]>         Exact directories to skip measuring.
  -o <output_csv_basename>   Output filename under ./output. Default: expired_files_rcp.csv.
  -O <output_directory>      Directory for CSV and summary files.
  --resume                   Resume from the last path already present in each output CSV.
  --summary-only             Do not scan, only print and write summary for existing CSV output.
EOF
}

detect_default_base_dirs() {
    local user_name="${USER:-$(whoami 2>/dev/null)}"
    local -a candidates=(
        "/mnt/vita/scratch/vita-staff/users/$user_name"
        "/mnt/vita/scratch/users/$user_name"
        "/mnt/vita/scratch/$user_name"
        "/work/vita/$user_name"
        "/work/vita"
    )
    local candidate

    if [ -n "${CHECK_FILES_BASE_DIRS:-}" ]; then
        IFS=',' read -ra base_dirs <<< "${CHECK_FILES_BASE_DIRS}"
        return
    fi

    for candidate in "${candidates[@]}"; do
        if [ -d "$candidate" ]; then
            base_dirs+=("$candidate")
            break
        fi
    done

    if [ ${#base_dirs[@]} -eq 0 ]; then
        base_dirs+=("$PWD")
    fi
}

split_csv_arg_into() {
    local raw_value="$1"
    local target_name="$2"
    local -n target_ref="$target_name"
    local -a parsed=()
    IFS=',' read -ra parsed <<< "$raw_value"
    target_ref+=("${parsed[@]}")
}

is_excluded_dir() {
    local dir="$1"
    local excluded
    for excluded in "${excluded_dirs[@]}"; do
        if [[ "$dir" == "$excluded" ]]; then
            return 0
        fi
    done
    return 1
}

relative_depth() {
    local base_dir="${1%/}"
    local dir="${2%/}"
    local relative_path

    if [[ "$dir" == "$base_dir" ]]; then
        echo 0
        return
    fi

    relative_path="${dir#"$base_dir"/}"
    awk -F'/' '{print NF}' <<< "$relative_path"
}

csv_last_directory() {
    local csv_file="$1"
    awk -F',' 'NR > 1 && NF {last=$1} END {gsub(/^"|"$/, "", last); print last}' "$csv_file"
}

format_bytes_human() {
    local bytes="$1"
    if command -v numfmt >/dev/null 2>&1; then
        numfmt --to=iec --suffix=B "$bytes"
    else
        printf '%sB\n' "$bytes"
    fi
}

parse_size_bytes() {
    local size_value="$1"
    local parsed_size
    size_value="${size_value%B}"
    if command -v numfmt >/dev/null 2>&1; then
        parsed_size=$(numfmt --from=iec "$size_value" 2>/dev/null) || return 1
        printf '%s\n' "$parsed_size"
        return 0
    fi
    return 1
}

summary_file_for() {
    local csv_file="$1"
    printf '%s.summary.txt\n' "${csv_file%.*}"
}

write_summary() {
    local csv_file="$1"
    local label="$2"
    local summary_file
    summary_file=$(summary_file_for "$csv_file")

    if [ ! -s "$csv_file" ]; then
        {
            echo "Summary for $label"
            echo "CSV: $csv_file"
            echo "No output generated."
        } > "$summary_file"
        cat "$summary_file" >&2
        return
    fi

    local entry_count
    entry_count=$(awk 'NR > 1 && NF {count++} END {print count + 0}' "$csv_file")

    local oversize_count
    oversize_count=$(awk -F',' 'NR > 1 && $2 ~ /"TOO_LARGE"/ {count++} END {print count + 0}' "$csv_file")

    local total_bytes=0
    if command -v numfmt >/dev/null 2>&1; then
        local size_value
        local parsed_size
        while IFS= read -r size_value; do
            [ -z "$size_value" ] && continue
            parsed_size=$(parse_size_bytes "$size_value") || continue
            total_bytes=$((total_bytes + parsed_size))
        done < <(awk -F',' 'NR > 1 {gsub(/"/, "", $2); if ($2 != "TOO_LARGE" && $2 != "") print $2}' "$csv_file")
    fi

    local total_display="unknown"
    if [ "$total_bytes" -gt 0 ]; then
        total_display=$(format_bytes_human "$total_bytes")
    elif [ "$entry_count" -gt 0 ] && [ "$oversize_count" -lt "$entry_count" ]; then
        total_display="0B"
    fi

    {
        echo "Summary for $label"
        echo "CSV: $csv_file"
        echo "Entries: $entry_count"
        echo "TOO_LARGE entries: $oversize_count"
        echo "Total known size: $total_display"
        echo
        echo "Largest entries:"
        awk -F',' 'NR > 1 {gsub(/"/, "", $1); gsub(/"/, "", $2); if ($2 != "TOO_LARGE" && $2 != "") print $1 "\t" $2}' "$csv_file" \
            | while IFS=$'\t' read -r path size; do
                [ -z "$path" ] && continue
                parsed_size=$(parse_size_bytes "$size") || parsed_size=0
                printf "%s\t%s\n" "$parsed_size" "$path ($size)"
            done \
            | sort -nr \
            | head -n "$summary_limit" \
            | awk -F'\t' '{print "- " $2}'
        echo
        echo "Oldest modified entries:"
        awk -F',' 'NR > 1 {gsub(/"/, "", $1); gsub(/"/, "", $2); gsub(/"/, "", $3); if ($2 != "") print $3 "\t" $1 "\t" $2}' "$csv_file" \
            | sort \
            | head -n "$summary_limit" \
            | awk -F'\t' '{print "- " $2 " (" $3 ", modified " $1 ")"}'
    } > "$summary_file"

    cat "$summary_file" >&2
}

log_expired_dirs_with_size() {
    local base_dir="$1"
    local log_file="$2"
    local resume_after="${3:-}"
    local min_size_bytes=$((min_size_gb * 1024 * 1024 * 1024))

    if [ ! -d "$base_dir" ]; then
        echo "Skipping missing base directory: $base_dir" >&2
        return
    fi

    if [ "$resume" = true ] && [ -s "$log_file" ]; then
        echo "Resume mode: appending to existing log $log_file" >&2
    else
        echo '"Directory","Size","Modified","Accessed"' > "$log_file"
    fi

    echo "Scanning $base_dir" >&2
    echo "  expired_only=$expired_only min_size_gb=$min_size_gb timeout_seconds=$timeout_seconds max_depth=$max_depth measure_min_depth=$measure_min_depth" >&2

    local -a dirs_to_check=()
    if [ "$expired_only" = true ]; then
        mapfile -t dirs_to_check < <(find "$base_dir" -mindepth 1 -maxdepth "$max_depth" -type d -mtime +"$expiration_days" 2>/dev/null)
    else
        mapfile -t dirs_to_check < <(find "$base_dir" -mindepth 1 -maxdepth "$max_depth" -type d 2>/dev/null)
    fi

    local total_dirs=${#dirs_to_check[@]}
    echo "  found $total_dirs candidate directories" >&2

    local resume_enabled=false
    local skipped_due_resume=0
    local idx
    if [ -n "$resume_after" ]; then
        for idx in "${!dirs_to_check[@]}"; do
            if [[ "${dirs_to_check[$idx]}" == "$resume_after" ]]; then
                resume_enabled=true
                skipped_due_resume=$((idx + 1))
                echo "  resume marker found: $resume_after" >&2
                echo "  skipping $skipped_due_resume already-recorded directories" >&2
                break
            fi
        done
        if [ "$resume_enabled" = false ]; then
            echo "  resume requested, but marker not found under $base_dir; starting from the beginning" >&2
        fi
    fi

    local skip_until_resume="$resume_enabled"
    local count=0
    local -A processed_dirs=()
    local dir
    for dir in "${dirs_to_check[@]}"; do
        if [ "$skip_until_resume" = true ]; then
            if [[ "$dir" == "$resume_after" ]]; then
                skip_until_resume=false
            fi
            continue
        fi

        if [ "${processed_dirs[$dir]:-0}" = "1" ]; then
            continue
        fi
        processed_dirs["$dir"]=1

        if is_excluded_dir "$dir"; then
            echo "[$((count + 1))/$total_dirs] Skipping excluded directory: $dir" >&2
            continue
        fi

        local dir_depth
        dir_depth=$(relative_depth "$base_dir" "$dir")
        if [ "$dir_depth" -lt "$measure_min_depth" ]; then
            echo "[$((count + 1))/$total_dirs] Skipping shallow directory: $dir (depth $dir_depth < $measure_min_depth)" >&2
            continue
        fi

        count=$((count + 1))
        echo "[$count/$total_dirs] Checking $dir" >&2

        local size_bytes
        size_bytes=$(timeout "$timeout_seconds" du -s -B1 "$dir" 2>/dev/null | awk '{print $1}')
        if [ -n "$size_bytes" ]; then
            if [ "$size_bytes" -ge "$min_size_bytes" ]; then
                local size_human
                local modified_date
                local accessed_date
                size_human=$(format_bytes_human "$size_bytes")
                modified_date=$(stat -c %y "$dir" 2>/dev/null || echo "unknown")
                accessed_date=$(stat -c %x "$dir" 2>/dev/null || echo "unknown")
                printf '"%s","%s","%s","%s"\n' "$dir" "$size_human" "$modified_date" "$accessed_date" >> "$log_file"
                echo "  match: $size_human" >&2
            fi
            continue
        fi

        local modified_date
        local accessed_date
        modified_date=$(stat -c %y "$dir" 2>/dev/null || echo "unknown")
        accessed_date=$(stat -c %x "$dir" 2>/dev/null || echo "unknown")
        printf '"%s","%s","%s","%s"\n' "$dir" "TOO_LARGE" "$modified_date" "$accessed_date" >> "$log_file"
        echo "  timed out, marked as TOO_LARGE" >&2

        local -a subdirs=()
        local subdir
        mapfile -t subdirs < <(find "$dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
        for subdir in "${subdirs[@]}"; do
            if [ "${processed_dirs[$subdir]:-0}" = "1" ]; then
                continue
            fi
            processed_dirs["$subdir"]=1

            if is_excluded_dir "$subdir"; then
                continue
            fi

            echo "  checking child $subdir" >&2
            local sub_size_bytes
            sub_size_bytes=$(timeout "$timeout_seconds" du -s -B1 "$subdir" 2>/dev/null | awk '{print $1}')
            if [ -n "$sub_size_bytes" ]; then
                if [ "$sub_size_bytes" -ge "$min_size_bytes" ]; then
                    local sub_size_human
                    local sub_modified_date
                    local sub_accessed_date
                    sub_size_human=$(format_bytes_human "$sub_size_bytes")
                    sub_modified_date=$(stat -c %y "$subdir" 2>/dev/null || echo "unknown")
                    sub_accessed_date=$(stat -c %x "$subdir" 2>/dev/null || echo "unknown")
                    printf '"%s","%s","%s","%s"\n' "$subdir" "$sub_size_human" "$sub_modified_date" "$sub_accessed_date" >> "$log_file"
                    echo "    child match: $sub_size_human" >&2
                fi
            else
                local sub_modified_date
                local sub_accessed_date
                sub_modified_date=$(stat -c %y "$subdir" 2>/dev/null || echo "unknown")
                sub_accessed_date=$(stat -c %x "$subdir" 2>/dev/null || echo "unknown")
                printf '"%s","%s","%s","%s"\n' "$subdir" "TOO_LARGE" "$sub_modified_date" "$sub_accessed_date" >> "$log_file"
                echo "    child timed out, marked as TOO_LARGE" >&2
            fi
        done
    done

    echo "Finished $base_dir: processed $count directories from $total_dirs candidates" >&2
}

while [ $# -gt 0 ]; do
    case "$1" in
        -e)
            expired_only=true
            ;;
        -m)
            [ $# -lt 2 ] && { echo "Missing value for -m" >&2; print_usage; exit 1; }
            min_size_gb="$2"
            shift
            ;;
        -t)
            [ $# -lt 2 ] && { echo "Missing value for -t" >&2; print_usage; exit 1; }
            timeout_seconds="$2"
            shift
            ;;
        -d)
            [ $# -lt 2 ] && { echo "Missing value for -d" >&2; print_usage; exit 1; }
            max_depth="$2"
            shift
            ;;
        --measure-mindepth)
            [ $# -lt 2 ] && { echo "Missing value for --measure-mindepth" >&2; print_usage; exit 1; }
            measure_min_depth="$2"
            shift
            ;;
        -a)
            [ $# -lt 2 ] && { echo "Missing value for -a" >&2; print_usage; exit 1; }
            expiration_days="$2"
            shift
            ;;
        -b)
            [ $# -lt 2 ] && { echo "Missing value for -b" >&2; print_usage; exit 1; }
            split_csv_arg_into "$2" user_base_dirs
            shift
            ;;
        -x)
            [ $# -lt 2 ] && { echo "Missing value for -x" >&2; print_usage; exit 1; }
            split_csv_arg_into "$2" excluded_dirs
            shift
            ;;
        -o)
            [ $# -lt 2 ] && { echo "Missing value for -o" >&2; print_usage; exit 1; }
            log_basename="$2"
            shift
            ;;
        -O)
            [ $# -lt 2 ] && { echo "Missing value for -O" >&2; print_usage; exit 1; }
            OUTPUT_DIR="$2"
            shift
            ;;
        --resume)
            resume=true
            ;;
        --summary-only)
            summary_only=true
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
    shift
done

if [ ${#user_base_dirs[@]} -gt 0 ]; then
    base_dirs=("${user_base_dirs[@]}")
else
    detect_default_base_dirs
fi

if [ -z "$OUTPUT_DIR" ]; then
    OUTPUT_DIR="${base_dirs[0]%/}/check-clean-files/output"
fi

mkdir -p "$OUTPUT_DIR"

log_stem="$log_basename"
log_ext=""
if [[ "$log_basename" == *.* ]]; then
    log_stem="${log_basename%.*}"
    log_ext=".${log_basename##*.}"
fi

declare -a log_files=()
if [ ${#base_dirs[@]} -gt 1 ]; then
    for i in "${!base_dirs[@]}"; do
        log_files+=("$OUTPUT_DIR/${log_stem}_$((i + 1))${log_ext}")
    done
else
    log_files+=("$OUTPUT_DIR/${log_stem}${log_ext}")
fi

if [ "$summary_only" = true ]; then
    for i in "${!log_files[@]}"; do
        write_summary "${log_files[$i]}" "${base_dirs[$i]}"
    done
    exit 0
fi

declare -a resume_dirs=()
if [ "$resume" = true ]; then
    for log_file in "${log_files[@]}"; do
        if [ -f "$log_file" ]; then
            resume_dirs+=("$(csv_last_directory "$log_file")")
        else
            resume_dirs+=("")
        fi
    done
fi

echo "Base directories: ${base_dirs[*]}" >&2
if [ ${#excluded_dirs[@]} -gt 0 ]; then
    echo "Excluded directories: ${excluded_dirs[*]}" >&2
fi

for i in "${!base_dirs[@]}"; do
    resume_arg=""
    if [ "$resume" = true ]; then
        resume_arg="${resume_dirs[$i]}"
    fi
    log_expired_dirs_with_size "${base_dirs[$i]}" "${log_files[$i]}" "$resume_arg"
    write_summary "${log_files[$i]}" "${base_dirs[$i]}"
done
