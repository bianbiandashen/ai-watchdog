#!/usr/bin/env bash
# Personal memory module — summarize recent Claude/Codex sessions every 30 min
# Writes to ~/billion-smart/<project>/summaries/ (per-repo) or _global/summaries/
# Uses LiteLLM-compatible API (reads from .env, never committed)

SMART_HOME="$HOME/billion-smart"
ENV_FILE="${WATCHDOG_HOME}/.env"

# Resolve a working directory to a billion-smart folder
# Compatible with bash 3.2 (macOS default) — no associative arrays
resolve_project() {
    local cwd="$1"
    case "$cwd" in
        */devin|*/devin/*)                           echo "devin" ;;
        */orba-desktop|*/orba-desktop/*)             echo "orba-desktop" ;;
        */orba-memorybank-cli|*/orba-memorybank-cli/*) echo "orba-memorybank-cli" ;;
        */orba|*/orba/*)                             echo "orba" ;;
        */ai-watchdog|*/ai-watchdog/*)               echo "ai-watchdog" ;;
        *)                                           echo "_global" ;;
    esac
}

load_api_config() {
    if [[ -f "$ENV_FILE" ]]; then
        set -a
        source "$ENV_FILE"
        set +a
    fi
    OPENAI_API_KEY="${OPENAI_API_KEY:-}"
    OPENAI_BASE_URL="${OPENAI_BASE_URL:-}"
    SUMMARY_MODEL="${SUMMARY_MODEL:-anthropic/claude-opus-4.6}"
}

call_llm_raw() {
    local system_prompt="$1"
    local user_prompt="$2"
    local max_tokens="${3:-2048}"
    [[ -z "$OPENAI_API_KEY" ]] && { log_warn "MEMORY: No API key"; return 1; }

    local payload
    payload=$(python3 -c "
import json, sys
system_p = sys.argv[1]
user_p = sys.stdin.read()
print(json.dumps({
    'model': '$SUMMARY_MODEL',
    'max_tokens': $max_tokens,
    'messages': [
        {'role': 'system', 'content': system_p},
        {'role': 'user', 'content': user_p}
    ]
}))
" "$system_prompt" <<< "$user_prompt")

    local response
    response=$(curl -s --max-time 90 \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${OPENAI_API_KEY}" \
        "${OPENAI_BASE_URL}/chat/completions" \
        -d "$payload")

    echo "$response" | python3 -c "
import json, sys
try:
    d = json.loads(sys.stdin.read())
    print(d['choices'][0]['message']['content'])
except Exception as e:
    print(f'(summarization failed: {e})')
" 2>/dev/null
}

call_llm() {
    local prompt="$1"
    local max_tokens="${2:-1024}"
    call_llm_raw "You are a concise technical summarizer. Output markdown. Focus on: what was asked, what was decided, key learnings. Keep under 500 words." "$prompt" "$max_tokens"
}

# Scan recent Claude sessions, group by project directory
scan_recent_sessions() {
    local marker="/tmp/.watchdog-memory-marker"
    [[ ! -f "$marker" ]] && touch -t "$(date -v-30M '+%Y%m%d%H%M.%S')" "$marker" 2>/dev/null

    python3 - "$HOME/.claude/projects" "$marker" <<'PYEOF'
import os, sys, json, stat

projects_dir = sys.argv[1]
marker = sys.argv[2]
marker_mtime = os.stat(marker).st_mtime if os.path.exists(marker) else 0

results = {}  # cwd -> list of messages

for project_name in os.listdir(projects_dir):
    project_path = os.path.join(projects_dir, project_name)
    if not os.path.isdir(project_path):
        continue

    # Decode project dir name to cwd: -Users-billion-bian-devin -> /Users/billion_bian/devin
    cwd = '/' + project_name.lstrip('-').replace('-', '/')

    for fname in os.listdir(project_path):
        if not fname.endswith('.jsonl'):
            continue
        fpath = os.path.join(project_path, fname)
        if os.stat(fpath).st_mtime < marker_mtime:
            continue

        # Read last 30 messages
        try:
            with open(fpath) as f:
                lines = f.readlines()[-30:]
            for line in lines:
                try:
                    d = json.loads(line)
                    role = d.get('type', d.get('role', ''))
                    msg = d.get('message', {})
                    content = msg.get('content', '') if isinstance(msg, dict) else str(msg)
                    if isinstance(content, list):
                        texts = [c.get('text', '') for c in content if isinstance(c, dict) and c.get('type') == 'text']
                        content = ' '.join(texts)
                    if content and role in ('user', 'assistant'):
                        text = str(content).strip()[:300]
                        if text and len(text) > 10:
                            if cwd not in results:
                                results[cwd] = []
                            results[cwd].append(f'[{role}] {text}')
                except:
                    pass
        except:
            pass

# Output: one line per project, tab-separated: cwd \t message_count \t context_preview
for cwd, msgs in results.items():
    context = '\n'.join(msgs[-20:])  # last 20 messages per project
    # Print as: cwd<TAB>count<TAB>context (context newlines escaped)
    escaped = context.replace('\n', '\\n').replace('\t', ' ')
    print(f'{cwd}\t{len(msgs)}\t{escaped}')
PYEOF
}

generate_summary() {
    load_api_config
    mkdir -p "$SMART_HOME/_global/summaries"

    local marker="/tmp/.watchdog-memory-marker"

    # Scan sessions grouped by project
    local found_any=false
    while IFS=$'\t' read -r cwd count context; do
        [[ -z "$cwd" || -z "$context" ]] && continue
        (( count < 3 )) && continue  # skip very short sessions
        found_any=true

        # Resolve to billion-smart folder
        local project
        project=$(resolve_project "$cwd")
        local out_dir="${SMART_HOME}/${project}/summaries"
        mkdir -p "$out_dir"

        log_info "MEMORY: Summarizing $cwd ($count msgs) -> $project"

        # Unescape context
        local real_context
        real_context=$(echo -e "$context")

        local summary
        summary=$(call_llm "You are running the COMPOUND STEP from compound-engineering methodology.
Analyze this AI coding session in project '$cwd' and extract structured learnings.

## Output these 5 sections:

### What Worked
- Approaches, tools, patterns that succeeded (reuse next time)

### What Failed
- Dead ends, wrong assumptions, wasted effort (avoid next time)

### Key Decisions
- What was chosen and WHY (preserve the reasoning for future context)

### Learnings (HIGHEST VALUE)
- Non-obvious discoveries, gotchas, performance insights
- Things that would save 30+ minutes if known upfront
- Format each as: **[topic]**: learning (so it's scannable)

### Open Issues
- Unresolved problems, TODOs, things to revisit

--- SESSION ($count messages) ---
$real_context
--- END ---

Be concise. Focus on what's REUSABLE across future sessions, not what's ephemeral.")

        if [[ -n "$summary" && "$summary" != *"summarization failed"* ]]; then
            local ts
            ts=$(date '+%Y%m%d_%H%M')
            cat > "${out_dir}/${ts}.md" <<EOF
# Session Summary — $(date '+%Y-%m-%d %H:%M')
**Project:** $cwd
**Messages:** $count

$summary

---
_Generated by ai-watchdog memory module_
EOF
            log_info "MEMORY: Saved ${out_dir}/${ts}.md"
        fi

        # Keep only last 48 summaries per project
        ls -t "${out_dir}"/*.md 2>/dev/null | tail -n +49 | xargs rm -f 2>/dev/null

    done < <(scan_recent_sessions)

    if ! $found_any; then
        log_debug "MEMORY: No recent session activity to summarize"
    fi

    touch "$marker"
}

list_recent_summaries() {
    local n="${1:-5}"
    find "$SMART_HOME" -name '*.md' -path '*/summaries/*' -type f 2>/dev/null | xargs ls -t 2>/dev/null | head -"$n"
}

list_best_practices() {
    ls "${SMART_HOME}/best-practices/"*.md 2>/dev/null
}

# Re-index billion-smart into PageIndex after summaries are written
run_pageindex_reindex() {
    local venv_python="${SMART_HOME}/.venv/bin/python"
    local reindex_script="${SMART_HOME}/reindex.py"
    [[ ! -x "$venv_python" || ! -f "$reindex_script" ]] && {
        log_debug "PAGEINDEX: venv or reindex.py not found, skipping"
        return 0
    }
    log_info "PAGEINDEX: Re-indexing billion-smart into PageIndex..."
    "$venv_python" "$reindex_script" 2>&1 | while read -r line; do
        log_debug "PAGEINDEX: $line"
    done
    log_info "PAGEINDEX: Reindex complete"
}

# Trigger LLM-powered session summary refresh via web server API
refresh_dashboard_summaries() {
    # Web server must be running on port 7474
    if ! curl -s --max-time 3 "http://127.0.0.1:7474/api/status" >/dev/null 2>&1; then
        log_debug "SUMMARY: Web server not reachable, skipping"
        return 0
    fi
    log_info "SUMMARY: Refreshing LLM session summaries..."
    local result
    result=$(curl -s --max-time 120 -X POST "http://127.0.0.1:7474/api/refresh-summaries" 2>/dev/null)
    log_info "SUMMARY: $result"
}
