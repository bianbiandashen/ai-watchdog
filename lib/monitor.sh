#!/usr/bin/env bash
# Process monitoring: memory pressure, orphan detection

check_memory_pressure() {
    local free_mb; free_mb=$(get_free_mem_mb)
    if (( free_mb < SYSTEM_MEM_CRITICAL_MB )); then
        log_error "CRITICAL memory: ${free_mb}MB free"
        return 2
    elif (( free_mb < SYSTEM_MEM_MIN_FREE_MB )); then
        log_warn "LOW memory: ${free_mb}MB free"
        return 1
    fi
    log_debug "Memory OK: ${free_mb}MB free"
    return 0
}

# Emit lines: "pid label mem_mb" for each orphaned MCP server process
find_orphan_mcp_procs() {
    for pattern in "${ORPHAN_TARGET_PATTERNS[@]}"; do
        local pids=() orphan_pids=()
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            local pid; pid=$(awk '{print $2}' <<< "$line")
            pids+=("$pid")
            is_orphan "$pid" && orphan_pids+=("$pid") || true
        done < <(ps aux | grep -E "$pattern" | grep -v grep)

        local total=${#pids[@]}
        local orphan_count=${#orphan_pids[@]}

        (( total == 0 )) && continue

        if (( orphan_count > 0 )); then
            log_debug "Orphan MCP: pattern='$pattern' total=$total orphans=$orphan_count"
            for pid in "${orphan_pids[@]+"${orphan_pids[@]}"}"; do
                local mem; mem=$(get_process_mem_mb "$pid")
                echo "$pid $pattern $mem"
            done
        fi

        # Swarm: even if parents alive, if N >> threshold kill oldest
        if (( total > ORPHAN_THRESHOLD )); then
            local keep=$ORPHAN_THRESHOLD
            local to_kill=$(( total - keep ))
            local killed_extra=0
            # Sort by start time ascending (oldest first) and kill extras
            while IFS= read -r line; do
                [[ -z "$line" ]] && continue
                (( killed_extra >= to_kill )) && break
                local pid; pid=$(awk '{print $2}' <<< "$line")
                # Skip if already in orphan_pids list
                local already=false
                for op in "${orphan_pids[@]+"${orphan_pids[@]}"}"; do [[ "$op" == "$pid" ]] && already=true && break; done
                [[ "$already" == "true" ]] && continue || true
                local mem; mem=$(get_process_mem_mb "$pid")
                echo "$pid $pattern $mem"
                killed_extra=$(( killed_extra + 1 ))
            done < <(ps aux | grep -E "$pattern" | grep -v grep | sort -k9,9)
        fi
    done
}

# Emit lines: "pid label mem_mb" for per-process memory hogs
find_memory_hogs() {
    for pattern in "${ORPHAN_TARGET_PATTERNS[@]}"; do
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            local pid mem_kb; pid=$(awk '{print $2}' <<< "$line"); mem_kb=$(awk '{print $6}' <<< "$line")
            local mem_mb=$(( mem_kb / 1024 ))
            (( mem_mb > PROCESS_MEM_MAX_MB )) && echo "$pid $pattern $mem_mb"
        done < <(ps aux | grep -E "$pattern" | grep -v grep)
    done
}

# Returns JSON-like summary for TUI
get_system_stats() {
    local free_mb; free_mb=$(get_free_mem_mb)
    local total_mb; total_mb=$(get_total_mem_mb)
    local used_mb=$(( total_mb - free_mb ))
    local used_pct=$(( used_mb * 100 / total_mb ))
    echo "$free_mb $total_mb $used_pct"
}

# Collect counts of all watched process groups
get_process_counts() {
    for pattern in "${ORPHAN_TARGET_PATTERNS[@]}" "${MONITOR_ONLY_PATTERNS[@]}"; do
        local count=0 mem_total=0
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            local mem_kb; mem_kb=$(awk '{print $6}' <<< "$line")
            count=$(( count + 1 ))
            mem_total=$(( mem_total + mem_kb / 1024 ))
        done < <(ps aux | grep -E "$pattern" | grep -v 'grep\|watchdog')
        (( count > 0 )) && printf '%s\t%d\t%d\n' "$pattern" "$count" "$mem_total"
    done
}

# Save snapshot to disk
save_snapshot() {
    mkdir -p "$SNAPSHOT_DIR"
    local snap="${SNAPSHOT_DIR}/$(date +%Y%m%d_%H%M%S).txt"
    {
        echo "=== AI Watchdog Snapshot $(date) ==="
        echo ""
        echo "--- System ---"
        top -l 1 -n 0 -s 0 2>/dev/null | grep -E '(PhysMem|Processes:)'
        echo ""
        echo "--- MCP Orphan Targets ---"
        for pat in "${ORPHAN_TARGET_PATTERNS[@]}"; do
            local c; c=$(ps aux | grep -cE "$pat" 2>/dev/null || echo 0)
            (( c > 1 )) && printf '  %-40s %d\n' "$pat" "$((c-1))"
        done
        echo ""
        echo "--- Top 15 by RSS ---"
        ps aux | sort -k6 -rn | head -16 | awk '{printf "  PID=%-6s RSS=%-8s %s\n", $2, $6"K", substr($11,1,60)}'
    } > "$snap" 2>&1
    ls -t "${SNAPSHOT_DIR}"/*.txt 2>/dev/null | tail -n +51 | xargs rm -f 2>/dev/null
    log_debug "Snapshot: $snap"
}
