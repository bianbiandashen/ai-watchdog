#!/usr/bin/env bash
# Anomaly Detector Skill — threshold checks on health data
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${SCRIPT_DIR}/config.sh"

input=$(cat)

python3 -c "
import json, sys

try:
    d = json.loads('''$input''') if '''$input'''.strip() else json.loads(sys.stdin.read())
except:
    try:
        d = json.loads(sys.stdin.read())
    except:
        d = {}

anomalies = []
severity = 'none'

free_mb = d.get('memory_free_mb', d.get('free_mb', 99999))
used_pct = d.get('memory_used_pct', 0)
mcp_count = d.get('mcp_process_count', d.get('mcp_count', 0))
tool_count = d.get('tool_process_count', d.get('tool_count', 0))

if used_pct > 90:
    anomalies.append({'type': 'memory_critical', 'detail': f'Memory usage at {used_pct}%', 'threshold': 90})
    severity = 'high'
elif used_pct > 80:
    anomalies.append({'type': 'memory_high', 'detail': f'Memory usage at {used_pct}%', 'threshold': 80})
    if severity == 'none': severity = 'medium'

if free_mb < 1024:
    anomalies.append({'type': 'memory_low', 'detail': f'Only {free_mb}MB free', 'threshold': 1024})
    severity = 'high'

if mcp_count > 20:
    anomalies.append({'type': 'mcp_swarm', 'detail': f'{mcp_count} MCP processes', 'threshold': 20})
    if severity in ('none', 'low'): severity = 'medium'
elif mcp_count > 10:
    anomalies.append({'type': 'mcp_elevated', 'detail': f'{mcp_count} MCP processes', 'threshold': 10})
    if severity == 'none': severity = 'low'

recommendations = []
if any(a['type'].startswith('memory') for a in anomalies):
    recommendations.append('Run: ./watchdog.sh clean')
    recommendations.append('Consider closing unused AI tool sessions')
if any(a['type'].startswith('mcp') for a in anomalies):
    recommendations.append('Check for orphan MCP servers: ./watchdog.sh once')
    recommendations.append('Review MCP server configurations in your AI tools')

print(json.dumps({
    'anomalies': anomalies,
    'severity': severity,
    'anomaly_count': len(anomalies),
    'recommendations': recommendations
}, indent=2))
" <<< "$input"
