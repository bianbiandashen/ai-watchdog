#!/usr/bin/env bash
# Cleanup: kill MCP server orphans and old logs

cleanup_orphans() {
    local killed=0 freed_mb=0

    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        local pid label mem
        read -r pid label mem <<< "$entry"
        if safe_kill "$pid" "$label"; then
            killed=$(( killed + 1 ))
            freed_mb=$(( freed_mb + mem ))
        fi
    done < <(find_orphan_mcp_procs)

    if (( killed > 0 )); then
        log_info "Orphan cleanup: killed=$killed freed=${freed_mb}MB"
        notify "Orphan Cleanup" "Killed $killed MCP orphans, freed ~${freed_mb}MB"
    fi
    return 0
}

cleanup_memory_hogs() {
    local killed=0 freed_mb=0

    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        local pid label mem
        read -r pid label mem <<< "$entry"
        log_warn "Memory hog: PID=$pid ${mem}MB ($label)"
        if safe_kill "$pid" "hog:$label"; then
            killed=$(( killed + 1 ))
            freed_mb=$(( freed_mb + mem ))
        fi
    done < <(find_memory_hogs)

    if (( killed > 0 )); then
        log_info "Hog cleanup: killed=$killed freed=${freed_mb}MB"
        notify "Memory Hog Killed" "Killed $killed processes, freed ~${freed_mb}MB"
    fi
    return 0
}

emergency_cleanup() {
    log_error "EMERGENCY: system memory critical, aggressive MCP cleanup"
    notify "EMERGENCY" "Memory critical! Killing all MCP orphans."
    save_snapshot

    # Kill all orphan MCP servers without threshold
    for pattern in "${ORPHAN_TARGET_PATTERNS[@]}"; do
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            local pid; pid=$(awk '{print $2}' <<< "$line")
            safe_kill "$pid" "emergency:$pattern" || true
        done < <(ps aux | grep -E "$pattern" | grep -v grep)
    done

    local free_after; free_after=$(get_free_mem_mb)
    log_info "Emergency done: ${free_after}MB free"
    notify "Emergency Done" "Memory freed. ${free_after}MB now available."
}

cleanup_old_logs() {
    local cleaned=0 freed=0
    for dir in "${LOG_SCAN_DIRS[@]}"; do
        [[ ! -d "$dir" ]] && continue
        for pat in "${LOG_CLEAN_PATTERNS[@]}"; do
            while IFS= read -r f; do
                [[ -z "$f" ]] && continue
                local sz; sz=$(stat -f%z "$f" 2>/dev/null || echo 0)
                rm -f "$f" && cleaned=$(( cleaned + 1 )) && freed=$(( freed + sz ))
            done < <(find "$dir" -name "$pat" -mtime "+${LOG_MAX_AGE_DAYS}" -type f 2>/dev/null)
        done
    done
    (( cleaned > 0 )) && log_info "Log cleanup: $cleaned files, $(( freed/1024/1024 ))MB freed"
    return 0
}
