#!/usr/bin/env bash
# ai-watchdog daemon — 7x24 AI tool process guardian
# Monitors ~/.claude ~/.codex ~/.orba, kills MCP orphans, never touches CLI sessions
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"
source "${SCRIPT_DIR}/lib/utils.sh"
source "${SCRIPT_DIR}/lib/monitor.sh"
source "${SCRIPT_DIR}/lib/cleanup.sh"
source "${SCRIPT_DIR}/lib/recovery.sh"

mkdir -p "$LOG_DIR" "$SNAPSHOT_DIR"

PID_FILE="${LOG_DIR}/watchdog.pid"
STATE_FILE="${LOG_DIR}/state.json"

# ── Stats tracking ────────────────────────────────────────────────────────────
TOTAL_ORPHANS_KILLED=0
TOTAL_MB_FREED=0
CYCLES=0
START_TIME=$(date +%s)

write_state() {
    local free_mb; free_mb=$(get_free_mem_mb)
    local ts; ts=$(date +%s)
    cat > "$STATE_FILE" <<JSON
{
  "pid": $$,
  "started": $START_TIME,
  "last_update": $ts,
  "cycle": $CYCLES,
  "total_orphans_killed": $TOTAL_ORPHANS_KILLED,
  "total_mb_freed": $TOTAL_MB_FREED,
  "free_mb": $free_mb
}
JSON
}

check_single_instance() {
    if [[ -f "$PID_FILE" ]]; then
        local old_pid; old_pid=$(cat "$PID_FILE")
        if kill -0 "$old_pid" 2>/dev/null; then
            echo "Watchdog already running (PID $old_pid). Run ./status.sh to check."
            exit 1
        fi
        rm -f "$PID_FILE"
    fi
    echo $$ > "$PID_FILE"
}

on_exit() {
    rm -f "$PID_FILE"
    log_info "Watchdog stopped (PID $$, cycles=$CYCLES)"
}

# ── Main loop ─────────────────────────────────────────────────────────────────
main_loop() {
    log_info "══════════════════════════════════════════"
    log_info "AI Watchdog started  PID=$$  interval=${CHECK_INTERVAL}s"
    log_info "MCP orphan targets:  ${#ORPHAN_TARGET_PATTERNS[@]} patterns"
    log_info "Monitor-only:        ${#MONITOR_ONLY_PATTERNS[@]} patterns"
    log_info "══════════════════════════════════════════"
    notify "AI Watchdog" "Started. Monitoring AI tools every ${CHECK_INTERVAL}s."

    while true; do
        CYCLES=$(( CYCLES + 1 ))
        rotate_log

        # 1. Memory pressure check
        local mem_status=0
        check_memory_pressure || mem_status=$?

        if (( mem_status == 2 )); then
            # Critical — emergency kill
            emergency_cleanup
        elif (( mem_status == 1 )); then
            # Low — targeted orphan + hog cleanup
            cleanup_orphans
            cleanup_memory_hogs
            # Re-check; if still low → emergency
            check_memory_pressure 2>/dev/null || emergency_cleanup
        fi

        # 2. Always scan for MCP orphan swarms
        cleanup_orphans

        # 3. Periodic log cleanup (every 60 cycles ≈ 30 min)
        if (( CYCLES % 60 == 0 )); then
            cleanup_old_logs
            save_snapshot
        fi

        # 4. State file (for TUI)
        write_state

        # 5. Hourly health log
        if (( CYCLES % 120 == 0 )); then
            local free_mb; free_mb=$(get_free_mem_mb)
            log_info "HEALTH cycle=$CYCLES free=${free_mb}MB killed_total=${TOTAL_ORPHANS_KILLED}"
        fi

        sleep "$CHECK_INTERVAL"
    done
}

# ── CLI dispatcher ────────────────────────────────────────────────────────────
cmd="${1:-run}"
case "$cmd" in
    run)
        check_single_instance
        trap on_exit EXIT INT TERM
        main_loop
        ;;
    once)
        log_info "Single cycle"
        check_memory_pressure || true
        cleanup_orphans
        cleanup_memory_hogs
        free_mb=$(get_free_mem_mb)
        echo "Free memory: ${free_mb}MB"
        ;;
    clean)
        log_info "Manual cleanup"
        cleanup_orphans
        cleanup_memory_hogs
        cleanup_old_logs
        echo "Done. Free: $(get_free_mem_mb)MB"
        ;;
    snapshot)
        save_snapshot
        echo "Snapshot saved to ${SNAPSHOT_DIR}/"
        ;;
    recover)
        source "${SCRIPT_DIR}/lib/recovery.sh"
        show_recovery_menu
        ;;
    *)
        echo "Usage: $0 {run|once|clean|snapshot|recover}"
        echo ""
        echo "  run       Start 7x24 daemon"
        echo "  once      Single scan cycle"
        echo "  clean     Manual cleanup now"
        echo "  snapshot  Save diagnostic snapshot"
        echo "  recover   Interactive session recovery menu"
        exit 1
        ;;
esac
