# Parse the NUL-delimited metadata stream emitted by audit_cold_files.sh.
# File contents are never opened: every input field comes from find(1) metadata.

BEGIN {
    RS = "\0"
    OFS = "\t"
    total_files = 0
    cold_files = 0
    total_logical_bytes = 0
    total_allocated_bytes = 0
    cold_logical_bytes = 0
    cold_allocated_bytes = 0
}

function csv(value, escaped) {
    escaped = value
    gsub(/"/, "\"\"", escaped)
    return "\"" escaped "\""
}

function iso8601(epoch) {
    return strftime("%Y-%m-%dT%H:%M:%SZ", int(epoch), 1)
}

function relative_path(path, relative) {
    relative = path
    if (substr(relative, 1, length(base_dir) + 1) == base_dir "/") {
        relative = substr(relative, length(base_dir) + 2)
    }
    return relative
}

function directory_group(path, relative, parts, count, idx, group) {
    relative = relative_path(path)
    count = split(relative, parts, "/")
    group = base_dir
    for (idx = 1; idx <= group_depth && idx < count; idx++) {
        group = group "/" parts[idx]
    }
    return group
}

function extension_for(path, name, parts, count) {
    count = split(path, parts, "/")
    name = tolower(parts[count])
    if (name !~ /\./ || name ~ /^\.[^.]+$/) {
        return "[no extension]"
    }
    sub(/^.*\./, ".", name)
    return name
}

function classify(path, lower) {
    lower = tolower(path)

    if (lower ~ /(^|\/)(\.cache|cache|caches|hf_cache|huggingface|torch_extensions|__pycache__|tmp|temp)(\/|$)/ ||
        lower ~ /\.(tmp|temp|part|partial|lock)$/) {
        class_name = "CACHE_OR_TEMP"
        suggestion = "CANDIDATE_AFTER_CHECK"
        reason = "Cache or temporary data; normally reproducible, but confirm its source first."
    } else if (lower ~ /(^|\/)(wandb|tensorboard|lightning_logs|logs?)(\/|$)/ ||
               lower ~ /\.(log|out|err)$/) {
        class_name = "TRAINING_LOG"
        suggestion = "CANDIDATE_AFTER_CHECK"
        reason = "Old logs are often dispensable after retaining metrics and final reports."
    } else if (lower ~ /(^|\/)(checkpoints?|ckpts?)(\/|$)/ ||
               lower ~ /\.(ckpt|pt|pth|safetensors|bin)$/) {
        class_name = "MODEL_OR_CHECKPOINT"
        suggestion = "REVIEW"
        reason = "Keep final/best LoRA adapters and provenance; intermediate checkpoints may be removable."
    } else if (lower ~ /(^|\/)(outputs?|runs?|results?|samples?|predictions?|eval|evaluation)(\/|$)/) {
        class_name = "TRAINING_OUTPUT"
        suggestion = "REVIEW"
        reason = "Derived output may be reproducible; retain final artifacts, configs, metrics, and representative samples."
    } else if (lower ~ /\.(wav|flac|mp3|ogg|opus|m4a|aac|aiff|aif|wma)$/) {
        class_name = "AUDIO_DATA"
        suggestion = "KEEP_OR_MIGRATE"
        reason = "Audio may be source or restored training data; do not delete based on age alone."
    } else if (lower ~ /(^|\/)(datasets?|corpus|corpora|raw|original|source)(\/|$)/) {
        class_name = "DATASET"
        suggestion = "KEEP_OR_MIGRATE"
        reason = "Dataset-like path; keep or migrate unless a verified canonical copy exists."
    } else if (lower ~ /\.(tar|tgz|tar\.gz|tar\.bz2|tar\.xz|zip|7z|rar|gz|bz2|xz|zst)$/) {
        class_name = "ARCHIVE"
        suggestion = "REVIEW"
        reason = "Archive may duplicate extracted data, but verify integrity and uniqueness before deletion."
    } else if (lower ~ /\.(py|sh|bash|zsh|json|jsonl|ya?ml|toml|ini|cfg|conf|txt|md|csv|tsv)$/) {
        class_name = "CODE_CONFIG_OR_METADATA"
        suggestion = "KEEP_OR_MIGRATE"
        reason = "Small reproducibility or metadata file; retain with the associated project."
    } else {
        class_name = "OTHER"
        suggestion = "REVIEW"
        reason = "No reliable deletion decision can be inferred from the path and metadata alone."
    }
}

function process_file(atime_epoch, mtime_epoch, logical_bytes, blocks, device, inode, owner, path,
                      allocated_bytes, inode_key, counted_allocated, group, extension, age_days) {
    total_files++
    logical_bytes += 0
    allocated_bytes = (blocks + 0) * 512
    total_logical_bytes += logical_bytes

    inode_key = device ":" inode
    counted_allocated = 0
    if (!(inode_key in seen_inode)) {
        seen_inode[inode_key] = 1
        counted_allocated = allocated_bytes
        total_allocated_bytes += allocated_bytes
    }

    group = directory_group(path)
    group_total_files[group]++

    if ((atime_epoch + 0) >= cutoff_epoch) {
        return
    }

    cold_files++
    cold_logical_bytes += logical_bytes
    cold_allocated_bytes += counted_allocated
    group_cold_files[group]++
    group_cold_logical[group] += logical_bytes
    group_cold_allocated[group] += counted_allocated

    if (!(group in group_oldest_atime) || atime_epoch < group_oldest_atime[group]) {
        group_oldest_atime[group] = atime_epoch
    }
    if (!(group in group_newest_atime) || atime_epoch > group_newest_atime[group]) {
        group_newest_atime[group] = atime_epoch
    }

    extension = extension_for(path)
    extension_files[extension]++
    extension_logical[extension] += logical_bytes
    extension_allocated[extension] += counted_allocated

    classify(relative_path(path))
    class_files[class_name]++
    class_logical[class_name] += logical_bytes
    class_allocated[class_name] += counted_allocated
    age_days = int((scan_epoch - atime_epoch) / 86400)

    print csv(path) "," logical_bytes "," allocated_bytes "," counted_allocated "," \
          csv(iso8601(atime_epoch)) "," csv(iso8601(mtime_epoch)) "," csv(owner) "," \
          age_days "," csv(class_name) "," csv(suggestion) "," csv(reason) ",\"\"" >> cold_csv
}

{
    position = (NR - 1) % 8
    if (position == 0) {
        record_atime = $0
    } else if (position == 1) {
        record_mtime = $0
    } else if (position == 2) {
        record_size = $0
    } else if (position == 3) {
        record_blocks = $0
    } else if (position == 4) {
        record_device = $0
    } else if (position == 5) {
        record_inode = $0
    } else if (position == 6) {
        record_owner = $0
    } else {
        process_file(record_atime, record_mtime, record_size, record_blocks,
                     record_device, record_inode, record_owner, $0)
    }
}

END {
    for (group in group_cold_files) {
        print group_cold_allocated[group] + 0, group_cold_logical[group] + 0,
              group_cold_files[group] + 0, group_total_files[group] + 0,
              iso8601(group_oldest_atime[group]), iso8601(group_newest_atime[group]), group > directory_raw
    }
    for (extension in extension_files) {
        print extension_allocated[extension] + 0, extension_logical[extension] + 0,
              extension_files[extension] + 0, extension > extension_raw
    }
    for (class in class_files) {
        print class_allocated[class] + 0, class_logical[class] + 0,
              class_files[class] + 0, class > class_raw
    }

    print "scan_epoch\t" scan_epoch > stats_file
    print "cutoff_epoch\t" cutoff_epoch >> stats_file
    print "total_files\t" total_files >> stats_file
    print "cold_files\t" cold_files >> stats_file
    print "total_logical_bytes\t" total_logical_bytes >> stats_file
    print "total_allocated_bytes\t" total_allocated_bytes >> stats_file
    print "cold_logical_bytes\t" cold_logical_bytes >> stats_file
    print "cold_allocated_bytes\t" cold_allocated_bytes >> stats_file
}
