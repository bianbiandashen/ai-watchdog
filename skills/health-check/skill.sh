#!/usr/bin/env bash
# Health Check Skill — collects system metrics and produces health assessment
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${SCRIPT_DIR}/config.sh"

page_size=$(sysctl -n hw.pagesize 2>/dev/null || echo 4096)
free_pages=$(vm_stat 2>/dev/null | awk '/Pages free/{gsub(/\./,"",$3); print $3}')
inactive=$(vm_stat 2>/dev/null | awk '/Pages inactive/{gsub(/\./,"",$3); print $3}')
purgeable=$(vm_stat 2>/dev/null | awk '/Pages purgeable/{gsub(/\./,"",$3); print $3}')
free_mb=$(( (${free_pages:-0} + ${inactive:-0} + ${purgeable:-0}) * page_size / 1024 / 1024 ))
total_mb=$(sysctl -n hw.memsize 2>/dev/null | awk '{print int($1/1024/1024)}')
used_pct=$(( (total_mb - free_mb) * 100 / total_mb ))

mcp_count=0
for pat in "${ORPHAN_TARGET_PATTERNS[@]}"; do
    c=$(ps aux | grep -E "$pat" 2>/dev/null | grep -cv grep)
    mcp_count=$(( mcp_count + c ))
done

tool_count=0
for pat in "${MONITOR_ONLY_PATTERNS[@]}"; do
    c=$(ps aux | grep -E "$pat" 2>/dev/null | grep -cv grep)
    tool_count=$(( tool_count + c ))
done

log_size=$(du -sm "${LOG_DIR}" 2>/dev/null | awk '{print $1}' || echo 0)
uptime_str=$(uptime | awk -F'( |,)' '{print $5,$6}')

status="ok"
alerts="[]"
(( used_pct > 85 )) && status="warning"
(( used_pct > 95 )) && status="critical"
(( mcp_count > 15 )) && status="warning"

python3 -c "
import json
alerts = []
if $used_pct > 85: alerts.append('High memory usage: ${used_pct}%')
if $mcp_count > 15: alerts.append('MCP process swarm: $mcp_count')
if ${log_size:-0} > 400: alerts.append('Log directory large: ${log_size}MB')
print(json.dumps({
    'status': '$status',
    'memory_free_mb': $free_mb,
    'memory_total_mb': $total_mb,
    'memory_used_pct': $used_pct,
    'mcp_process_count': $mcp_count,
    'tool_process_count': $tool_count,
    'log_size_mb': ${log_size:-0},
    'uptime': '$uptime_str',
    'alerts': alerts
}))
"
