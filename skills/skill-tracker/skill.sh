#!/usr/bin/env bash
# Skill Tracker — analyze tool and skill usage patterns from Claude/Codex sessions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${SCRIPT_DIR}/config.sh"

input=$(cat)
hours=$(echo "$input" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('hours',24))" 2>/dev/null || echo 24)

python3 - "$HOME/.claude/projects" "$hours" <<'PYEOF'
import os, sys, json, time, collections, glob

projects_dir = sys.argv[1]
hours = int(sys.argv[2])
cutoff = time.time() - hours * 3600

tools = collections.Counter()
skills_used = collections.Counter()
project_tools = collections.defaultdict(lambda: collections.Counter())
sessions_scanned = 0
total_messages = 0

for pdir in glob.glob(projects_dir + '/*/'):
    pname = os.path.basename(pdir.rstrip('/'))
    cwd = '/' + pname.lstrip('-').replace('-', '/')

    for fpath in glob.glob(pdir + '*.jsonl'):
        if os.stat(fpath).st_mtime < cutoff:
            continue
        sessions_scanned += 1

        try:
            for line in open(fpath):
                try:
                    d = json.loads(line)
                    msg = d.get('message', {})
                    if not isinstance(msg, dict):
                        continue
                    role = d.get('type', d.get('role', ''))
                    content = msg.get('content', [])

                    # Count tool_use calls from assistant
                    if isinstance(content, list):
                        for c in content:
                            if isinstance(c, dict) and c.get('type') == 'tool_use':
                                name = c.get('name', '')
                                if name:
                                    tools[name] += 1
                                    project_tools[cwd][name] += 1

                    # Count slash command usage from user messages
                    if role == 'user':
                        text = ''
                        if isinstance(content, str):
                            text = content
                        elif isinstance(content, list):
                            text = ' '.join(c.get('text', '') for c in content if isinstance(c, dict) and c.get('type') == 'text')
                        # Only match real slash commands, not URL paths
                        for word in text.split():
                            if word.startswith('/') and len(word) > 2 and len(word) < 25:
                                # Filter out URL-like patterns
                                if not any(x in word for x in ['://', '/*', '/**', '.', '\\n', '\\', ',']):
                                    skills_used[word] += 1

                    total_messages += 1
                except:
                    pass
        except:
            pass

# Build top 5 tools with contextual suggestions
tool_suggestions = {
    'Bash': 'Most commands run via Bash — consider if dedicated tools (Read/Edit/Grep) could replace some shell calls for better UX.',
    'Read': 'Heavy file reading — your workflow is exploration-heavy. Consider using Agent/Explore for broader codebase searches.',
    'Edit': 'Lots of edits — productive session! If you find yourself doing similar edits repeatedly, ask Claude to write a codemod.',
    'Write': 'Creating many new files — make sure you are extending existing files where possible rather than creating new ones.',
    'Grep': 'Search-heavy session — if searches keep returning too many results, try using the Agent tool with Explore subagent.',
    'Glob': 'File discovery — you are navigating unfamiliar territory. Consider adding key file paths to CLAUDE.md for future sessions.',
    'Agent': 'Using sub-agents — great for parallelization. Tip: be very specific in agent prompts for better results.',
    'TaskCreate': 'Task tracking active — you are working on complex multi-step tasks. Good discipline.',
    'TaskUpdate': 'Actively updating tasks — indicates structured workflow. Keep it up.',
    'Skill': 'Using slash-command skills — check available skills with /help to discover more.',
    'WebFetch': 'Fetching web content — consider caching results if you fetch the same URL multiple times.',
    'WebSearch': 'Web searching — results may be more current than Claude knowledge. Good for recent docs.',
    'EnterPlanMode': 'Planning before coding — this leads to better architecture decisions.',
    'ExitPlanMode': 'Completing plans — make sure the plan file captures key decisions for future reference.',
    'AskUserQuestion': 'Clarifying requirements — good practice, prevents wasted effort.',
    'NotebookEdit': 'Jupyter notebook work — consider converting key findings to markdown for CLAUDE.md.',
}

top_5 = []
for tool, count in tools.most_common(5):
    suggestion = tool_suggestions.get(tool, f'Used {tool} {count} times — consider if there are patterns to automate.')
    # Find which projects use this tool most
    top_projects = sorted(
        [(p, c[tool]) for p, c in project_tools.items() if tool in c],
        key=lambda x: -x[1]
    )[:3]
    top_5.append({
        'tool': tool,
        'count': count,
        'suggestion': suggestion,
        'top_projects': [{'project': p, 'count': c} for p, c in top_projects]
    })

# Session patterns
patterns = []
total_tool_calls = sum(tools.values())
if total_tool_calls > 0:
    read_pct = tools.get('Read', 0) / total_tool_calls * 100
    edit_pct = tools.get('Edit', 0) / total_tool_calls * 100
    bash_pct = tools.get('Bash', 0) / total_tool_calls * 100

    if read_pct > 40:
        patterns.append('Exploration-heavy: >40% reads — you may be in discovery/debugging mode')
    if edit_pct > 30:
        patterns.append('Edit-heavy: >30% edits — productive implementation session')
    if bash_pct > 50:
        patterns.append('Shell-heavy: >50% Bash — consider using dedicated tools (Read/Edit/Grep) for better traceability')
    if tools.get('Agent', 0) > 3:
        patterns.append('Multi-agent workflow — you are parallelizing effectively')
    if tools.get('TaskCreate', 0) > 5:
        patterns.append('Complex task management — many sub-tasks created')
    if not patterns:
        patterns.append('Balanced tool usage — healthy mix of read/edit/shell')

result = {
    'period_hours': hours,
    'sessions_scanned': sessions_scanned,
    'total_messages': total_messages,
    'total_tool_calls': total_tool_calls,
    'tools': dict(tools.most_common(20)),
    'skills': dict(skills_used.most_common(10)),
    'top_5': top_5,
    'patterns': patterns,
}

print(json.dumps(result, indent=2))
PYEOF
