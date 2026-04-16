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
# Only kills true orphans: PPID=1 (launchd) or dead parent
find_orphan_mcp_procs() {
    for pattern in "${ORPHAN_TARGET_PATTERNS[@]}"; do
        local total=0 orphan_count=0
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            local pid; pid=$(awk '{print $2}' <<< "$line")
            total=$(( total + 1 ))
            if is_orphan "$pid"; then
                orphan_count=$(( orphan_count + 1 ))
                local mem; mem=$(get_process_mem_mb "$pid")
                log_debug "True orphan: pattern='$pattern' PID=$pid PPID=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ') mem=${mem}MB"
                echo "$pid $pattern $mem"
            fi
        done < <(ps aux | grep -E "$pattern" | grep -v 'grep\|watchdog')

        (( total > 0 && orphan_count > 0 )) && \
            log_info "Pattern '$pattern': $total total, $orphan_count orphans to kill"
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
