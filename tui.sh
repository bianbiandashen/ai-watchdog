#!/usr/bin/env bash
# ai-watchdog TUI — live 7x24 terminal dashboard
# Refresh every TUI_REFRESH seconds with ANSI drawing

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"
source "${SCRIPT_DIR}/lib/utils.sh"
source "${SCRIPT_DIR}/lib/monitor.sh"
source "${SCRIPT_DIR}/lib/recovery.sh"

# ── ANSI palette ──────────────────────────────────────────────────────────────
R=$'\033[0m'        # reset
BOLD=$'\033[1m'
DIM=$'\033[2m'
RED=$'\033[31m'
GRN=$'\033[32m'
YLW=$'\033[33m'
BLU=$'\033[34m'
MGT=$'\033[35m'
CYN=$'\033[36m'
WHT=$'\033[37m'
BG_DARK=$'\033[40m'

CLEAR_SCREEN=$'\033[2J\033[H'
HIDE_CURSOR=$'\033[?25l'
SHOW_CURSOR=$'\033[?25h'

cleanup_tui() {
    printf '%s' "$SHOW_CURSOR"
    tput rmcup 2>/dev/null || true
    echo ""
    echo "AI Watchdog TUI stopped."
    exit 0
}
trap cleanup_tui INT TERM EXIT

# ── Drawing helpers ───────────────────────────────────────────────────────────
move() { printf '\033[%d;%dH' "$1" "$2"; }   # row col

fill_bar() {
    local val="$1" max="$2" width="$3" color_ok="$4" color_warn="$5" color_bad="$6"
    local pct=$(( val * 100 / max ))
    local filled=$(( val * width / max ))
    local color
    if   (( pct < 60 )); then color="$color_ok"
    elif (( pct < 85 )); then color="$color_warn"
    else                      color="$color_bad"
    fi
    printf '%s' "$color"
    local i=0
    while (( i < filled  )); do printf '█'; i=$(( i+1 )); done
    while (( i < width   )); do printf '░'; i=$(( i+1 )); done
    printf '%s' "$R"
    printf ' %3d%%' "$pct"
}

hline() {
    local width="${1:-80}"
    printf '%s' "$DIM"
    printf '─%.0s' $(seq 1 "$width")
    printf '%s\n' "$R"
}

# ── Main render ───────────────────────────────────────────────────────────────
render() {
    local term_cols; term_cols=$(tput cols 2>/dev/null || echo 100)
    local term_rows; term_rows=$(tput lines 2>/dev/null || echo 40)
    local bar_width=$(( term_cols - 30 ))
    (( bar_width < 20 )) && bar_width=20

    printf '%s' "$CLEAR_SCREEN"

    # ── Header ────────────────────────────────────────────────────────────────
    local now; now=$(date '+%Y-%m-%d %H:%M:%S')
    printf "${BOLD}${CYN}  ╔══════════════════════════════════════════════════╗${R}\n"
    printf "${BOLD}${CYN}  ║   🔎  AI Watchdog  ·  7×24  ·  %-18s  ║${R}\n" "$now"
    printf "${BOLD}${CYN}  ╚══════════════════════════════════════════════════╝${R}\n"
    echo ""

    # ── Daemon status ─────────────────────────────────────────────────────────
    local pid_file="${LOG_DIR}/watchdog.pid"
    local daemon_status daemon_pid=""
    if [[ -f "$pid_file" ]]; then
        daemon_pid=$(cat "$pid_file" 2>/dev/null)
        if kill -0 "$daemon_pid" 2>/dev/null; then
            daemon_status="${GRN}${BOLD}● RUNNING${R} (PID $daemon_pid)"
        else
            daemon_status="${RED}${BOLD}● STALE${R}"
        fi
    else
        daemon_status="${YLW}${BOLD}● NOT STARTED${R}  run: ./install.sh"
    fi
    printf "  Daemon:   %b\n" "$daemon_status"

    # Uptime from state file
    if [[ -f "${LOG_DIR}/state.json" ]]; then
        local started cycles killed freed
        started=$(python3 -c "import json; d=json.load(open('${LOG_DIR}/state.json')); print(d.get('started',0))" 2>/dev/null || echo 0)
        cycles=$(python3 -c "import json; d=json.load(open('${LOG_DIR}/state.json')); print(d.get('cycle',0))" 2>/dev/null || echo 0)
        killed=$(python3 -c "import json; d=json.load(open('${LOG_DIR}/state.json')); print(d.get('total_orphans_killed',0))" 2>/dev/null || echo 0)
        freed=$(python3 -c "import json; d=json.load(open('${LOG_DIR}/state.json')); print(d.get('total_mb_freed',0))" 2>/dev/null || echo 0)
        if (( started > 0 )); then
            local uptime=$(( $(date +%s) - started ))
            local h=$(( uptime / 3600 )) m=$(( (uptime % 3600) / 60 )) s=$(( uptime % 60 ))
            printf "  Uptime:   ${WHT}%dh %dm %ds${R}   Cycles: ${WHT}%s${R}   Killed: ${GRN}%s orphans${R}   Freed: ${GRN}%sMB${R}\n" \
                "$h" "$m" "$s" "$cycles" "$killed" "$freed"
        fi
    fi
    echo ""
    hline "$term_cols"

    # ── Memory ────────────────────────────────────────────────────────────────
    local free_mb total_mb used_pct
    read -r free_mb total_mb used_pct <<< "$(get_system_stats)"
    local used_mb=$(( total_mb - free_mb ))
    printf "  ${BOLD}Memory${R}  ["; fill_bar "$used_mb" "$total_mb" "$bar_width" "$GRN" "$YLW" "$RED"
    printf "]  ${WHT}%dMB free / %dMB total${R}\n" "$free_mb" "$total_mb"

    # CPU (quick approximation via top -l 2)
    local cpu_user cpu_sys cpu_idle
    read -r cpu_user cpu_sys cpu_idle <<< "$(top -l 2 -n 0 -s 1 2>/dev/null | tail -1 | awk '{print $3, $5, $7}' | tr -d '%,' || echo '0 0 100')"
    local cpu_used=$(( ${cpu_user%.*} + ${cpu_sys%.*} ))
    printf "  ${BOLD}CPU   ${R}  ["; fill_bar "$cpu_used" 100 "$bar_width" "$GRN" "$YLW" "$RED"
    printf "]  ${WHT}user=%s%% sys=%s%% idle=%s%%${R}\n" "$cpu_user" "$cpu_sys" "$cpu_idle"
    echo ""
    hline "$term_cols"

    # ── MCP Orphan Targets ────────────────────────────────────────────────────
    printf "  ${BOLD}${MGT}MCP Server Processes${R}  ${DIM}(these are orphan-kill candidates)${R}\n"
    echo ""
    local found_any=false
    while IFS=$'\t' read -r pattern count mem; do
        found_any=true
        local color="$GRN"
        local flag=""
        if (( count > ORPHAN_THRESHOLD )); then
            color="$RED"; flag="  ${RED}${BOLD}⚠ SWARM${R}"
        fi
        printf "  ${color}%-40s${R}  %3d procs  %6dMB%b\n" "$pattern" "$count" "$mem" "$flag"
    done < <(
        for pattern in "${ORPHAN_TARGET_PATTERNS[@]}"; do
            local count=0 mem_total=0
            while IFS= read -r line; do
                [[ -z "$line" ]] && continue
                local mem_kb; mem_kb=$(awk '{print $6}' <<< "$line")
                count=$(( count + 1 )); mem_total=$(( mem_total + mem_kb / 1024 ))
            done < <(ps aux | grep -E "$pattern" | grep -v 'grep\|watchdog')
            (( count > 0 )) && printf '%s\t%d\t%d\n' "$pattern" "$count" "$mem_total"
        done
    )
    $found_any || printf "  ${DIM}(none running)${R}\n"
    echo ""
    hline "$term_cols"

    # ── Monitored tools ───────────────────────────────────────────────────────
    printf "  ${BOLD}${CYN}Monitored Tools${R}  ${DIM}(never killed)${R}\n"
    echo ""
    for pattern in "${MONITOR_ONLY_PATTERNS[@]}"; do
        local count=0 mem_total=0
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            local mem_kb; mem_kb=$(awk '{print $6}' <<< "$line")
            count=$(( count + 1 )); mem_total=$(( mem_total + mem_kb / 1024 ))
        done < <(ps aux | grep -E "$pattern" | grep -v 'grep\|watchdog')
        (( count > 0 )) && printf "  ${CYN}%-40s${R}  %3d procs  %6dMB\n" "$pattern" "$count" "$mem_total"
    done
    echo ""
    hline "$term_cols"

    # ── Recent Sessions (last 5 each) ─────────────────────────────────────────
    printf "  ${BOLD}${YLW}Recent Sessions${R}\n"
    echo ""
    printf "  ${GRN}${BOLD}Claude:${R}\n"
    local ci=0
    while IFS=$'\t' read -r ts sid cwd summary size; do
        ci=$(( ci + 1 ))
        local ds; ds=$(date -r "$ts" '+%m/%d %H:%M' 2>/dev/null || echo "???")
        local sz_kb=$(( size / 1024 ))
        printf "    ${GRN}c%d${R}  %-14s  %-24s  %-40s  ${DIM}%dKB${R}\n" \
            "$ci" "$ds" "${cwd:0:24}" "${summary:0:40}" "$sz_kb"
    done < <(list_claude_sessions 5)
    (( ci == 0 )) && printf "    ${DIM}(no sessions found)${R}\n"

    echo ""
    printf "  ${YLW}${BOLD}Codex:${R}\n"
    local di=0
    while IFS=$'\t' read -r ts sid cwd summary; do
        di=$(( di + 1 ))
        local ds; ds=$(date -r "$ts" '+%m/%d %H:%M' 2>/dev/null || echo "???")
        printf "    ${YLW}d%d${R}  %-14s  %-24s  %s\n" \
            "$di" "$ds" "${cwd:0:24}" "${summary:0:50}"
    done < <(list_codex_sessions 5)
    (( di == 0 )) && printf "    ${DIM}(no sessions found)${R}\n"

    echo ""
    hline "$term_cols"

    # ── Recent log tail ───────────────────────────────────────────────────────
    printf "  ${BOLD}Recent Log${R}\n\n"
    if [[ -f "$LOG_FILE" ]]; then
        tail -8 "$LOG_FILE" | while IFS= read -r line; do
            local color="$WHT"
            [[ "$line" == *"[ERROR]"* ]] && color="$RED"
            [[ "$line" == *"[WARN]"* ]]  && color="$YLW"
            [[ "$line" == *"[INFO]"* ]]  && color="$GRN"
            printf "  ${color}%s${R}\n" "${line:0:$(( term_cols - 4 ))}"
        done
    else
        printf "  ${DIM}(no log yet — daemon not started)${R}\n"
    fi
    echo ""

    # ── Footer ────────────────────────────────────────────────────────────────
    hline "$term_cols"
    printf "  ${DIM}[q] quit   [c] manual clean   [r] recover session   [s] snapshot   refresh in %ds${R}\n" \
        "$TUI_REFRESH"
}

# ── Event loop ────────────────────────────────────────────────────────────────
tput smcup 2>/dev/null || true
printf '%s' "$HIDE_CURSOR"

while true; do
    render

    # Non-blocking key read with timeout
    local_key=""
    IFS= read -r -s -n1 -t "$TUI_REFRESH" local_key 2>/dev/null || true

    case "$local_key" in
        q|Q) cleanup_tui ;;
        c|C)
            printf '%s' "$CLEAR_SCREEN"
            echo "Running manual cleanup..."
            source "${SCRIPT_DIR}/lib/cleanup.sh"
            cleanup_orphans
            cleanup_memory_hogs
            echo "Done. Press any key to continue."
            read -r -s -n1 2>/dev/null || true
            ;;
        r|R)
            printf '%s' "$SHOW_CURSOR"
            show_recovery_menu
            printf '%s' "$HIDE_CURSOR"
            ;;
        s|S)
            save_snapshot
            ;;
    esac
done
