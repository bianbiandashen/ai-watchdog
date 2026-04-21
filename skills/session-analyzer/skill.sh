#!/usr/bin/env bash
# Session Analyzer Skill — scan recent AI sessions for patterns
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${SCRIPT_DIR}/config.sh"

input=$(cat)
hours=$(echo "$input" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('hours',6))" 2>/dev/null || echo 6)

python3 - "$HOME/.claude/projects" "$hours" <<'PYEOF'
import os, sys, json, time

projects_dir = sys.argv[1]
hours = int(sys.argv[2])
cutoff = time.time() - hours * 3600

results = {"sessions": 0, "active_projects": [], "total_messages": 0, "patterns": []}
project_stats = {}

if os.path.isdir(projects_dir):
    for pname in os.listdir(projects_dir):
        ppath = os.path.join(projects_dir, pname)
        if not os.path.isdir(ppath):
            continue
        cwd = '/' + pname.lstrip('-').replace('-', '/')
        for fname in os.listdir(ppath):
            if not fname.endswith('.jsonl'):
                continue
            fpath = os.path.join(ppath, fname)
            if os.stat(fpath).st_mtime < cutoff:
                continue
            results["sessions"] += 1
            msg_count = 0
            try:
                with open(fpath) as f:
                    for line in f:
                        try:
                            d = json.loads(line)
                            if d.get('type','') in ('user','assistant') or d.get('role','') in ('user','assistant'):
                                msg_count += 1
                        except:
                            pass
            except:
                pass
            results["total_messages"] += msg_count
            if cwd not in project_stats:
                project_stats[cwd] = 0
            project_stats[cwd] += msg_count

for cwd, count in sorted(project_stats.items(), key=lambda x: -x[1]):
    results["active_projects"].append({"project": cwd, "messages": count})

if results["sessions"] > 5:
    results["patterns"].append("High activity: {} sessions in {}h".format(results["sessions"], hours))
if results["total_messages"] > 100:
    results["patterns"].append("Heavy usage: {} total messages".format(results["total_messages"]))
if len(project_stats) == 1:
    results["patterns"].append("Single-project focus")
elif len(project_stats) > 3:
    results["patterns"].append("Multi-project context switching ({} projects)".format(len(project_stats)))

print(json.dumps(results, indent=2))
PYEOF
