#!/usr/bin/env bash
# Quick status — no dependencies, runs fast
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

PID_FILE="${LOG_DIR}/watchdog.pid"
STATE_FILE="${LOG_DIR}/state.json"

echo "═══════════════════════════════════════════"
echo " AI Watchdog Status  —  $(date '+%Y-%m-%d %H:%M:%S')"
echo "═══════════════════════════════════════════"
echo ""

# Daemon
if [[ -f "$PID_FILE" ]]; then
    pid=$(cat "$PID_FILE")
    if kill -0 "$pid" 2>/dev/null; then
        echo "  Daemon:  RUNNING (PID $pid)"
    else
        echo "  Daemon:  STALE PID (PID $pid not alive)"
    fi
else
    echo "  Daemon:  NOT RUNNING  →  run ./install.sh"
fi

# Stats from state file
if [[ -f "$STATE_FILE" ]]; then
    python3 - <<PYEOF
import json, time, datetime
d = json.load(open('$STATE_FILE'))
started = d.get('started', 0)
uptime = int(time.time()) - started
h, rem = divmod(uptime, 3600); m, s = divmod(rem, 60)
print(f"  Uptime:  {h}h {m}m {s}s")
print(f"  Cycles:  {d.get('cycle',0)}")
print(f"  Killed:  {d.get('total_orphans_killed',0)} orphan MCP processes")
print(f"  Freed:   {d.get('total_mb_freed',0)} MB")
PYEOF
fi

echo ""

# Memory
page_size=$(sysctl -n hw.pagesize)
free_pages=$(vm_stat | awk '/Pages free/{gsub(/\./,"",$3); print $3}')
inactive=$(vm_stat | awk '/Pages inactive/{gsub(/\./,"",$3); print $3}')
purgeable=$(vm_stat | awk '/Pages purgeable/{gsub(/\./,"",$3); print $3}')
free_mb=$(( (free_pages + inactive + purgeable) * page_size / 1024 / 1024 ))
total_mb=$(sysctl -n hw.memsize | awk '{print int($1/1024/1024)}')
used_pct=$(( (total_mb - free_mb) * 100 / total_mb ))
echo "  Memory:  ${free_mb}MB free / ${total_mb}MB total (${used_pct}% used)"

# MCP orphan targets
echo ""
echo "  MCP Orphan Targets:"
for pattern in "${ORPHAN_TARGET_PATTERNS[@]}"; do
    count=$(ps aux | grep -E "$pattern" 2>/dev/null | grep -cv grep)
    if (( count > 0 )); then
        flag=""
        (( count > ORPHAN_THRESHOLD )) && flag="  ⚠ SWARM"
        printf "    %-42s %3d%s\n" "$pattern" "$count" "$flag"
    fi
done

# Monitored tools
echo ""
echo "  Monitored Tools (never killed):"
for pattern in "${MONITOR_ONLY_PATTERNS[@]}"; do
    count=$(ps aux | grep -E "$pattern" 2>/dev/null | grep -cv grep)
    (( count > 0 )) && printf "    %-42s %3d\n" "$pattern" "$count"
done

echo ""
echo "  Logs: ${LOG_DIR}/"
echo "  TUI:  ./tui.sh"
