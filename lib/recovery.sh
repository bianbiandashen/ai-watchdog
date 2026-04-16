#!/usr/bin/env bash
# Session recovery: list last 5 sessions per tool, offer resume

CLAUDE_PROJECTS_DIR="$HOME/.claude/projects"
CODEX_HISTORY="$HOME/.codex/history.jsonl"
ORBA_CONFIG="$HOME/.orba/.claude.json"

# ── Claude ────────────────────────────────────────────────────────────────────
list_claude_sessions() {
    local n="${1:-5}"
    # Each .jsonl file in any project dir is a session; filename = sessionId
    find "$CLAUDE_PROJECTS_DIR" -name '*.jsonl' -type f 2>/dev/null \
        | while read -r f; do
            local ts; ts=$(stat -f%m "$f" 2>/dev/null || echo 0)
            local session_id; session_id=$(basename "$f" .jsonl)
            local project_dir; project_dir=$(basename "$(dirname "$f")")
            # Convert dir path back: -Users-billion-bian -> /Users/billion_bian
            local cwd; cwd=$(echo "$project_dir" | sed 's|^-||; s|-|/|g')
            local size; size=$(stat -f%z "$f" 2>/dev/null || echo 0)
            # Try to extract first human message as summary
            local summary
            summary=$(python3 -c "
import json, sys
try:
    lines = open('$f').readlines()
    for line in lines:
        try:
            d = json.loads(line)
            if d.get('type') != 'user':
                continue
            # Claude Code format: message.content is array or string
            msg = d.get('message', {})
            if isinstance(msg, dict):
                content = msg.get('content', '')
            else:
                content = msg
            if isinstance(content, list):
                for c in content:
                    if isinstance(c, dict) and c.get('type') == 'text':
                        txt = str(c.get('text', '')).strip().split('\n')[0][:60]
                        if txt: print(txt); sys.exit(0)
            elif isinstance(content, str) and content.strip():
                print(content.strip().split('\n')[0][:60]); sys.exit(0)
        except: pass
except: pass
print('(no summary)')
" 2>/dev/null || echo "(no summary)")
            printf '%d\t%s\t%s\t%s\t%d\n' "$ts" "$session_id" "/$cwd" "$summary" "$size"
          done \
        | sort -rn \
        | head -"$n"
}

# ── Codex ─────────────────────────────────────────────────────────────────────
list_codex_sessions() {
    local n="${1:-5}"
    [[ ! -f "$CODEX_HISTORY" ]] && return
    python3 - "$CODEX_HISTORY" "$n" <<'PYEOF'
import json, sys, time

history_file = sys.argv[1]
n = int(sys.argv[2])

sessions = {}
with open(history_file) as f:
    for line in f:
        try:
            d = json.loads(line)
            sid = d.get('session_id', '')
            if not sid:
                continue
            ts = d.get('ts', 0)
            cwd = d.get('cwd', '')
            if sid not in sessions or ts > sessions[sid]['ts']:
                sessions[sid] = {'ts': ts, 'cwd': cwd, 'sid': sid, 'summary': ''}
            # Try to grab first user message as summary
            if not sessions[sid]['summary']:
                role = d.get('role', '')
                content = d.get('content', '')
                if role == 'user' and content:
                    if isinstance(content, list):
                        for c in content:
                            if isinstance(c, dict) and c.get('type') == 'input_text':
                                sessions[sid]['summary'] = str(c.get('text', ''))[:60]
                                break
                    elif isinstance(content, str):
                        sessions[sid]['summary'] = content[:60]
        except:
            pass

sorted_sessions = sorted(sessions.values(), key=lambda x: x['ts'], reverse=True)[:n]
for s in sorted_sessions:
    ts = s['ts']
    cwd = s['cwd'] or '~'
    print(f"{ts}\t{s['sid']}\t{cwd}\t{s['summary'] or '(no summary)'}")
PYEOF
}

# ── Orba ──────────────────────────────────────────────────────────────────────
get_orba_last_session() {
    [[ ! -f "$ORBA_CONFIG" ]] && return
    python3 -c "
import json
try:
    d = json.load(open('$ORBA_CONFIG'))
    sid = d.get('currentSessionId') or d.get('sessionId') or ''
    if sid:
        print(sid)
except: pass
" 2>/dev/null
}

# ── Resume helpers ────────────────────────────────────────────────────────────
resume_claude() {
    local session_id="$1"
    echo ""
    echo "  To resume this Claude session, run:"
    echo "    claude --resume $session_id"
    echo ""
}

resume_codex() {
    local session_id="$1"
    echo ""
    echo "  To resume this Codex session, run:"
    echo "    codex --session $session_id"
    echo ""
}

# ── Interactive recovery menu ────────────────────────────────────────────────
show_recovery_menu() {
    local C_BOLD='\033[1m'
    local C_CYAN='\033[36m'
    local C_GREEN='\033[32m'
    local C_YELLOW='\033[33m'
    local C_RESET='\033[0m'

    echo ""
    printf "${C_BOLD}${C_CYAN}=== Session Recovery ===${C_RESET}\n"
    echo ""

    # Claude sessions
    printf "${C_BOLD}Claude Sessions (last 5):${C_RESET}\n"
    local i=0
    declare -A session_map
    while IFS=$'\t' read -r ts sid cwd summary size; do
        i=$(( i + 1 ))
        local date_str; date_str=$(date -r "$ts" '+%m/%d %H:%M' 2>/dev/null || echo "unknown")
        printf "  ${C_GREEN}[c%d]${C_RESET} %-16s %-28s %s\n" "$i" "$date_str" "${cwd:0:28}" "${summary:0:45}"
        session_map["c$i"]="claude:$sid"
    done < <(list_claude_sessions 5)
    (( i == 0 )) && echo "  (no sessions found)"

    echo ""
    printf "${C_BOLD}Codex Sessions (last 5):${C_RESET}\n"
    local j=0
    while IFS=$'\t' read -r ts sid cwd summary; do
        j=$(( j + 1 ))
        local date_str; date_str=$(date -r "$ts" '+%m/%d %H:%M' 2>/dev/null || echo "unknown")
        printf "  ${C_YELLOW}[d%d]${C_RESET} %-16s %-28s %s\n" "$j" "$date_str" "${cwd:0:28}" "${summary:0:45}"
        session_map["d$j"]="codex:$sid"
    done < <(list_codex_sessions 5)
    (( j == 0 )) && echo "  (no sessions found)"

    echo ""
    printf "Enter session key (e.g. c1, d2) or ${C_BOLD}q${C_RESET} to quit: "
    read -r choice

    [[ "$choice" == "q" ]] && return 0

    local entry="${session_map[$choice]}"
    if [[ -z "$entry" ]]; then
        echo "Invalid choice."
        return 1
    fi

    local tool="${entry%%:*}"
    local sid="${entry#*:}"

    case "$tool" in
        claude) resume_claude "$sid" ;;
        codex)  resume_codex  "$sid" ;;
    esac
}
