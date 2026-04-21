#!/usr/bin/env bash
# Shared utilities

log() {
    local level="$1"; shift
    local msg="$*"
    local ts; ts="$(date '+%Y-%m-%d %H:%M:%S')"
    printf '[%s] [%-5s] %s\n' "$ts" "$level" "$msg" >> "$LOG_FILE"
    if [[ "$VERBOSE" == "true" ]] || [[ "$level" != "DEBUG" ]]; then
        printf '[%s] [%-5s] %s\n' "$ts" "$level" "$msg"
    fi
}
log_info()  { log "INFO"  "$@"; }
log_warn()  { log "WARN"  "$@"; }
log_error() { log "ERROR" "$@"; }
log_debug() { log "DEBUG" "$@"; }

notify() {
    local title="$1" message="$2"
    log_info "NOTIFY: $title — $message"
    [[ "$NOTIFY_ENABLED" != "true" ]] && return
    osascript -e "display notification \"$message\" with title \"AI Watchdog\" subtitle \"$title\"" 2>/dev/null &
    # Hermes multi-channel dispatch
    if [[ "${#HERMES_NOTIFY_CHANNELS[@]}" -gt 0 ]] 2>/dev/null; then
        hermes_notify_all "$title" "$message" &
    fi
}

get_free_mem_mb() {
    local page_size free_pages inactive_pages purgeable_pages
    page_size=$(sysctl -n hw.pagesize)
    free_pages=$(vm_stat | awk '/Pages free/{gsub(/\./,"",$3); print $3}')
    inactive_pages=$(vm_stat | awk '/Pages inactive/{gsub(/\./,"",$3); print $3}')
    purgeable_pages=$(vm_stat | awk '/Pages purgeable/{gsub(/\./,"",$3); print $3}')
    echo $(( (free_pages + inactive_pages + purgeable_pages) * page_size / 1024 / 1024 ))
}

get_total_mem_mb() {
    sysctl -n hw.memsize | awk '{print int($1/1024/1024)}'
}

get_process_mem_mb() {
    ps -o rss= -p "$1" 2>/dev/null | awk '{print int($1/1024)}' || echo 0
}

# Returns 0 (true) if this PID matches any NEVER_KILL pattern
is_protected() {
    local pid="$1"
    local cmd; cmd=$(ps -o command= -p "$pid" 2>/dev/null || echo "")
    [[ -z "$cmd" ]] && return 0
    for pat in "${NEVER_KILL_PATTERNS[@]}"; do
        if echo "$cmd" | grep -qE "$pat" 2>/dev/null; then
            return 0
        fi
    done
    return 1
}

# Returns 0 (true) if process parent is gone or is launchd (PID 1)
is_orphan() {
    local pid="$1"
    local ppid; ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [[ -z "$ppid" ]] && return 0
    [[ "$ppid" == "1" ]] && return 0
    kill -0 "$ppid" 2>/dev/null || return 0
    return 1
}

safe_kill() {
    local pid="$1" label="$2"
    # Already gone
    if ! kill -0 "$pid" 2>/dev/null; then
        log_debug "PID $pid already gone ($label)"
        return 1
    fi
    # Protected CLI tool
    if is_protected "$pid"; then
        log_debug "Skip protected PID $pid ($label)"
        return 1
    fi
    log_info "KILL PID $pid ($label)"
    kill "$pid" 2>/dev/null
    sleep 2
    if kill -0 "$pid" 2>/dev/null; then
        log_warn "PID $pid still alive, SIGKILL"
        kill -9 "$pid" 2>/dev/null
    fi
    return 0
}

rotate_log() {
    [[ ! -f "$LOG_FILE" ]] && return
    local size; size=$(stat -f%z "$LOG_FILE" 2>/dev/null || echo 0)
    if (( size > 10 * 1024 * 1024 )); then
        mv "$LOG_FILE" "${LOG_FILE}.$(date +%Y%m%d%H%M%S).bak"
        ls -t "${LOG_FILE}".*.bak 2>/dev/null | tail -n +6 | xargs rm -f 2>/dev/null
        log_info "Log rotated"
    fi
}

human_bytes() {
    local bytes="$1"
    if (( bytes >= 1073741824 )); then
        printf '%.1fGB' "$(echo "$bytes 1073741824" | awk '{printf "%.1f", $1/$2}')"
    elif (( bytes >= 1048576 )); then
        printf '%.0fMB' "$(echo "$bytes 1048576" | awk '{printf "%.0f", $1/$2}')"
    else
        printf '%.0fKB' "$(echo "$bytes 1024" | awk '{printf "%.0f", $1/$2}')"
    fi
}
