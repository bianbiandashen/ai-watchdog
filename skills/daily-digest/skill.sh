#!/usr/bin/env bash
# Daily Digest Skill — summarize daily learnings, score value, track trend
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${SCRIPT_DIR}/config.sh"

SMART_HOME="$HOME/billion-smart"
input=$(cat)
days=$(echo "$input" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('days',1))" 2>/dev/null || echo 1)

python3 - "$SMART_HOME" "$days" "$SCRIPT_DIR" <<'PYEOF'
import os, sys, json, time, glob
from datetime import datetime, timedelta

smart_home = sys.argv[1]
days = int(sys.argv[2])
watchdog_home = sys.argv[3]
cutoff = time.time() - days * 86400
now_str = datetime.now().strftime('%Y-%m-%d')

# ── Scan summaries per project ──
projects = {}
for entry in os.listdir(smart_home):
    if entry.startswith('.') or entry == 'pageindex-workspace':
        continue
    sum_dir = os.path.join(smart_home, entry, 'summaries')
    brain_dir = os.path.join(smart_home, entry, 'brain')
    if not os.path.isdir(sum_dir) and not os.path.isdir(brain_dir):
        continue

    p = {'name': entry, 'summaries': [], 'brain_files': [], 'total_size': 0}

    # Recent summaries
    if os.path.isdir(sum_dir):
        for f in sorted(os.listdir(sum_dir), reverse=True):
            fp = os.path.join(sum_dir, f)
            if os.stat(fp).st_mtime >= cutoff:
                content = open(fp).read()
                p['summaries'].append({'file': f, 'size': len(content), 'preview': content[:300]})
                p['total_size'] += len(content)

    # Brain files
    if os.path.isdir(brain_dir):
        for f in os.listdir(brain_dir):
            fp = os.path.join(brain_dir, f)
            if os.path.isfile(fp):
                size = os.stat(fp).st_size
                p['brain_files'].append({'file': f, 'size': size, 'empty': size == 0})
                p['total_size'] += size

    projects[entry] = p

# ── Score each project's knowledge value ──
scored = []
for name, p in projects.items():
    score = 0
    reasons = []

    # Summaries quantity (recent activity)
    n_sum = len(p['summaries'])
    if n_sum > 0:
        score += min(n_sum * 15, 40)
        reasons.append(f'{n_sum} summaries in {days}d')

    # Brain completeness
    non_empty_brains = [b for b in p['brain_files'] if not b['empty']]
    if len(non_empty_brains) >= 2:
        score += 25
        reasons.append('brain files populated')
    elif len(non_empty_brains) == 1:
        score += 10
        reasons.append('partial brain')

    # Content richness (total size)
    if p['total_size'] > 5000:
        score += 20
        reasons.append(f'{p["total_size"]//1024}KB of knowledge')
    elif p['total_size'] > 1000:
        score += 10

    # Staleness penalty
    if n_sum == 0 and p['total_size'] < 500:
        score = max(score - 20, 0)
        reasons.append('stale — no recent activity')

    score = min(score, 100)
    scored.append({
        'project': name,
        'score': score,
        'reasons': reasons,
        'summary_count': n_sum,
        'brain_files': len(p['brain_files']),
        'brain_empty': len([b for b in p['brain_files'] if b['empty']]),
        'total_kb': round(p['total_size'] / 1024, 1),
        'latest_summary_preview': p['summaries'][0]['preview'] if p['summaries'] else None
    })

scored.sort(key=lambda x: -x['score'])

# ── Track trend (append to history file) ──
trend_file = os.path.join(watchdog_home, 'memory', 'session', 'knowledge-trend.log')
os.makedirs(os.path.dirname(trend_file), exist_ok=True)
total_score = sum(s['score'] for s in scored)
avg_score = round(total_score / max(len(scored), 1), 1)
with open(trend_file, 'a') as f:
    f.write(f'[{now_str}] projects={len(scored)} avg_score={avg_score} total_kb={sum(s["total_kb"] for s in scored)}\n')

# ── Read recent trend for curve data ──
trend_data = []
try:
    with open(trend_file) as f:
        for line in f.readlines()[-30:]:  # last 30 entries
            line = line.strip()
            if not line:
                continue
            # Parse: [2026-04-21] projects=4 avg_score=45.0 total_kb=12.3
            parts = {}
            date = line[1:11] if line.startswith('[') else ''
            for token in line.split():
                if '=' in token:
                    k, v = token.split('=', 1)
                    try:
                        parts[k] = float(v)
                    except:
                        parts[k] = v
            if date:
                trend_data.append({'date': date, **parts})
except:
    pass

# ── Actions needed ──
actions = []
for s in scored:
    if s['brain_empty'] > 0:
        actions.append(f'{s["project"]}: {s["brain_empty"]} empty brain files — run Refresh Brains')
    if s['score'] < 20 and s['summary_count'] == 0:
        actions.append(f'{s["project"]}: no recent summaries — consider running a session')
    if s['score'] > 60 and s['brain_empty'] == 0:
        actions.append(f'{s["project"]}: high value ({s["score"]}) — good candidate for brain inject')

print(json.dumps({
    'date': now_str,
    'days_scanned': days,
    'projects': scored,
    'total_projects': len(scored),
    'average_score': avg_score,
    'trend': trend_data,
    'actions': actions
}, indent=2))
PYEOF
