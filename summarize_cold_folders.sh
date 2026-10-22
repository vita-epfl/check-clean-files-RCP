#!/bin/bash

set -euo pipefail

INPUT_CSV=""
OUTPUT_CSV=""
BASE_DIR="/mnt/vita-vldriving/scratch"

usage() {
    cat >&2 <<'EOF'
Usage: summarize_cold_folders.sh -i cold_files.csv -o cold_folders.csv [-b base_dir]

Aggregate a per-file cold audit without rescanning the source volume. Personal
spaces are grouped as users/<owner>/<project>; shared datasets, models, and
results are grouped as <area>/<name>.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        -i) INPUT_CSV=$2; shift 2 ;;
        -o) OUTPUT_CSV=$2; shift 2 ;;
        -b) BASE_DIR=${2%/}; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
    esac
done

[ -n "$INPUT_CSV" ] || { echo "-i is required" >&2; exit 2; }
[ -n "$OUTPUT_CSV" ] || { echo "-o is required" >&2; exit 2; }
[ -r "$INPUT_CSV" ] || { echo "Cannot read: $INPUT_CSV" >&2; exit 1; }

RAW_FILE=$(mktemp "${TMPDIR:-/tmp}/cold-folders.XXXXXX")
cleanup() {
    [[ "$RAW_FILE" == "${TMPDIR:-/tmp}"/cold-folders.* ]] && rm -f -- "$RAW_FILE"
}
trap cleanup EXIT

gawk -v base_dir="$BASE_DIR" '
function folder_for(path, relative, part, count, depth, idx, folder) {
    relative=path
    sub("^" base_dir "/", "", relative)
    count=split(relative, part, "/")

    if (part[1] == "users") {
        depth=3
    } else if (part[1] == "vita-staff" && part[2] == "users") {
        depth=4
    } else {
        depth=2
    }

    if (depth >= count) depth=count-1
    if (depth < 1) depth=1
    folder=base_dir
    for (idx=1; idx<=depth; idx++) folder=folder "/" part[idx]
    return folder
}

NR > 1 && match($0, /^"(([^"]|"")*)",([0-9]+),([0-9]+),([0-9]+),"([^"]+)",/, metadata) {
    path=metadata[1]
    gsub(/""/, "\"", path)
    folder=folder_for(path)
    logical[folder]+=metadata[3]
    allocated[folder]+=metadata[5]
    files[folder]++
    accessed=metadata[6]
    if (!(folder in oldest) || accessed < oldest[folder]) oldest[folder]=accessed
    if (!(folder in newest) || accessed > newest[folder]) newest[folder]=accessed

    if (match($0, /,"([^"]+)","([^"]+)","[^"]*",""$/, decision)) {
        if (decision[2] == "CANDIDATE_AFTER_CHECK") candidate[folder]++
        else if (decision[2] == "KEEP_OR_MIGRATE") keep[folder]++
        else review[folder]++
    }
}

END {
    for (folder in files) {
        print allocated[folder]+0 "\t" logical[folder]+0 "\t" files[folder]+0 "\t" \
              oldest[folder] "\t" newest[folder] "\t" candidate[folder]+0 "\t" \
              review[folder]+0 "\t" keep[folder]+0 "\t" folder
    }
}' "$INPUT_CSV" > "$RAW_FILE"

{
    printf '%s\n' '"Folder","AllocatedSize","LogicalSize","Files","OldestAccessUTC","NewestAccessUTC","CandidateFiles","ReviewFiles","KeepOrMigrateFiles","Decision"'
    sort -t $'\t' -k1,1nr "$RAW_FILE" | gawk -F '\t' '
        function csv(value, escaped) { escaped=value; gsub(/"/, "\"\"", escaped); return "\"" escaped "\"" }
        function human(bytes, value, unit, units) {
            units[0]="B"; units[1]="KiB"; units[2]="MiB"; units[3]="GiB"; units[4]="TiB"; units[5]="PiB"
            value=bytes+0; unit=0
            while (value >= 1024 && unit < 5) { value/=1024; unit++ }
            if (unit == 0) return sprintf("%.0f %s", value, units[unit])
            if (value >= 100) return sprintf("%.0f %s", value, units[unit])
            if (value >= 10) return sprintf("%.1f %s", value, units[unit])
            return sprintf("%.2f %s", value, units[unit])
        }
        { print csv($9) "," csv(human($1)) "," csv(human($2)) "," $3 "," csv($4) "," csv($5) "," $6 "," $7 "," $8 ",\"\"" }'
} > "$OUTPUT_CSV"

echo "Folder summary written to $OUTPUT_CSV" >&2
