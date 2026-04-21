#!/usr/bin/env bash
# Hermes Agent integration layer
# Multi-channel notifications, skills engine, tiered memory, health reporting, MoA analysis
# Inspired by Nous Research Hermes Agent architecture

# ── Channel Loading ──────────────────────────────────────────────────────────

hermes_load_channels() {
    HERMES_NOTIFY_CHANNELS=()
    local env_file="${WATCHDOG_HOME}/.env"
    [[ ! -f "$env_file" ]] && return

    local telegram_token="" telegram_chat="" discord_url="" slack_url=""
    local dingtalk_url="" dingtalk_secret="" feishu_url="" feishu_secret=""
    local generic_url=""

    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" != *=* ]] && continue
        local key="${line%%=*}" val="${line#*=}"
        val="${val%%#*}"
        val="${val#"${val%%[![:space:]]*}"}"
        val="${val%"${val##*[![:space:]]}"}"
        [[ -z "$val" ]] && continue
        case "$key" in
            TELEGRAM_BOT_TOKEN)   telegram_token="$val" ;;
            TELEGRAM_CHAT_ID)     telegram_chat="$val" ;;
            DISCORD_WEBHOOK_URL)  discord_url="$val" ;;
            SLACK_WEBHOOK_URL)    slack_url="$val" ;;
            DINGTALK_WEBHOOK_URL) dingtalk_url="$val" ;;
            DINGTALK_SECRET)      dingtalk_secret="$val" ;;
            FEISHU_WEBHOOK_URL)   feishu_url="$val" ;;
            FEISHU_SECRET)        feishu_secret="$val" ;;
            GENERIC_WEBHOOK_URL)  generic_url="$val" ;;
            MOA_MODELS)           HERMES_MOA_MODELS="$val" ;;
        esac
    done < "$env_file"

    [[ -n "$telegram_token" && -n "$telegram_chat" ]] && \
        HERMES_NOTIFY_CHANNELS+=("telegram:${telegram_token}:${telegram_chat}")
    [[ -n "$discord_url" ]] && HERMES_NOTIFY_CHANNELS+=("discord:${discord_url}")
    [[ -n "$slack_url" ]]   && HERMES_NOTIFY_CHANNELS+=("slack:${slack_url}")
    [[ -n "$dingtalk_url" ]] && HERMES_NOTIFY_CHANNELS+=("dingtalk:${dingtalk_url}:${dingtalk_secret}")
    [[ -n "$feishu_url" ]]  && HERMES_NOTIFY_CHANNELS+=("feishu:${feishu_url}:${feishu_secret}")
    [[ -n "$generic_url" ]] && HERMES_NOTIFY_CHANNELS+=("generic:${generic_url}")
}

# ── Multi-Channel Notification ───────────────────────────────────────────────

hermes_notify() {
    local channel_entry="$1" title="$2" message="$3"
    local type="${channel_entry%%:*}"
    local rest="${channel_entry#*:}"

    case "$type" in
        telegram)
            local token="${rest%%:*}" chat_id="${rest#*:}"
            local text; text=$(python3 -c "import json; print(json.dumps({'chat_id':'$chat_id','text':'*$title*\n$message','parse_mode':'Markdown'}))" 2>/dev/null)
            curl -s --max-time 10 -X POST "https://api.telegram.org/bot${token}/sendMessage" \
                -H "Content-Type: application/json" -d "$text" >/dev/null 2>&1 &
            ;;
        discord)
            local url="$rest"
            local payload; payload=$(python3 -c "import json; print(json.dumps({'content':'**$title**\n$message'}))" 2>/dev/null)
            curl -s --max-time 10 -X POST "$url" \
                -H "Content-Type: application/json" -d "$payload" >/dev/null 2>&1 &
            ;;
        slack)
            local url="$rest"
            local payload; payload=$(python3 -c "import json; print(json.dumps({'text':'*$title*\n$message'}))" 2>/dev/null)
            curl -s --max-time 10 -X POST "$url" \
                -H "Content-Type: application/json" -d "$payload" >/dev/null 2>&1 &
            ;;
        dingtalk)
            local url="${rest%%:*}" secret="${rest#*:}"
            local ts_ms; ts_ms=$(python3 -c "import time; print(int(time.time()*1000))")
            local sign=""
            if [[ -n "$secret" ]]; then
                sign=$(python3 -c "
import hmac, hashlib, base64, urllib.parse
ts='$ts_ms'; secret='$secret'
msg = f'{ts}\n{secret}'
h = hmac.new(secret.encode(), msg.encode(), hashlib.sha256).digest()
print(urllib.parse.quote_plus(base64.b64encode(h).decode()))
" 2>/dev/null)
                url="${url}&timestamp=${ts_ms}&sign=${sign}"
            fi
            local payload; payload=$(python3 -c "import json; print(json.dumps({'msgtype':'text','text':{'content':'[$title] $message'}}))" 2>/dev/null)
            curl -s --max-time 10 -X POST "$url" \
                -H "Content-Type: application/json" -d "$payload" >/dev/null 2>&1 &
            ;;
        feishu)
            local url="${rest%%:*}" secret="${rest#*:}"
            local ts_sec; ts_sec=$(date +%s)
            local sign=""
            if [[ -n "$secret" ]]; then
                sign=$(python3 -c "
import hmac, hashlib, base64
ts='$ts_sec'; secret='$secret'
msg = f'{ts}\n{secret}'
h = hmac.new(msg.encode(), b'', hashlib.sha256).digest()
print(base64.b64encode(h).decode())
" 2>/dev/null)
            fi
            local payload; payload=$(python3 -c "
import json
d = {'msg_type':'text','content':{'text':'[$title] $message'}}
if '$sign': d['timestamp']='$ts_sec'; d['sign']='$sign'
print(json.dumps(d))
" 2>/dev/null)
            curl -s --max-time 10 -X POST "$url" \
                -H "Content-Type: application/json" -d "$payload" >/dev/null 2>&1 &
            ;;
        generic)
            local url="$rest"
            local payload; payload=$(python3 -c "import json; print(json.dumps({'title':'$title','message':'$message','timestamp':'$(date -u +%Y-%m-%dT%H:%M:%SZ)'}))" 2>/dev/null)
            curl -s --max-time 10 -X POST "$url" \
                -H "Content-Type: application/json" -d "$payload" >/dev/null 2>&1 &
            ;;
    esac
    log_debug "HERMES: Notified via $type"
}

hermes_notify_all() {
    local title="$1" message="$2"
    [[ ${#HERMES_NOTIFY_CHANNELS[@]} -eq 0 ]] 2>/dev/null && return 0
    for entry in "${HERMES_NOTIFY_CHANNELS[@]}"; do
        hermes_notify "$entry" "$title" "$message"
    done
}

# ── Skills Engine ────────────────────────────────────────────────────────────

hermes_discover_skills() {
    python3 - "$HERMES_SKILLS_DIR" <<'PYEOF'
import os, sys, json
skills_dir = sys.argv[1]
skills = []
if os.path.isdir(skills_dir):
    for name in sorted(os.listdir(skills_dir)):
        d = os.path.join(skills_dir, name)
        manifest = os.path.join(d, 'SKILL.md')
        if os.path.isdir(d) and os.path.isfile(manifest):
            meta = {'name': name}
            with open(manifest) as f:
                for line in f:
                    if ':' in line:
                        k, v = line.split(':', 1)
                        meta[k.strip().lower()] = v.strip()
            skills.append(meta)
print(json.dumps(skills, indent=2))
PYEOF
}

hermes_execute_skill() {
    local name="$1" args_json="${2:-'{}'}"
    local skill_script="${HERMES_SKILLS_DIR}/${name}/skill.sh"
    if [[ ! -f "$skill_script" ]]; then
        echo '{"ok":false,"error":"skill not found: '"$name"'"}'
        return 1
    fi
    local result exit_code
    result=$(echo "$args_json" | bash "$skill_script" 2>/dev/null)
    exit_code=$?
    if (( exit_code == 0 )); then
        echo '{"ok":true,"result":'"${result:-'{}'}"'}'
    else
        echo '{"ok":false,"error":"skill exited with code '"$exit_code"'","output":'"$(python3 -c "import json; print(json.dumps('${result:-error}'))" 2>/dev/null)"'}'
    fi
}

# ── Health Reporting ─────────────────────────────────────────────────────────

hermes_health_report() {
    local free_mb; free_mb=$(get_free_mem_mb)
    local total_mb; total_mb=$(get_total_mem_mb)
    local used_pct=$(( (total_mb - free_mb) * 100 / total_mb ))
    local skill_count=0 channel_count="${#HERMES_NOTIFY_CHANNELS[@]}"
    [[ -d "$HERMES_SKILLS_DIR" ]] && skill_count=$(find "$HERMES_SKILLS_DIR" -name 'SKILL.md' -type f 2>/dev/null | wc -l | tr -d ' ')

    local mcp_count=0 tool_count=0
    for pat in "${ORPHAN_TARGET_PATTERNS[@]}"; do
        local c; c=$(ps aux | grep -E "$pat" 2>/dev/null | grep -cv grep)
        mcp_count=$(( mcp_count + c ))
    done
    for pat in "${MONITOR_ONLY_PATTERNS[@]}"; do
        local c; c=$(ps aux | grep -E "$pat" 2>/dev/null | grep -cv grep)
        tool_count=$(( tool_count + c ))
    done

    local mem_instant=0 mem_session=0 mem_overflow=0
    [[ -d "${HERMES_MEMORY_DIR}/instant" ]]  && mem_instant=$(ls "${HERMES_MEMORY_DIR}/instant" 2>/dev/null | wc -l | tr -d ' ')
    [[ -d "${HERMES_MEMORY_DIR}/session" ]]  && mem_session=$(ls "${HERMES_MEMORY_DIR}/session" 2>/dev/null | wc -l | tr -d ' ')
    [[ -d "${HERMES_MEMORY_DIR}/overflow" ]] && mem_overflow=$(ls "${HERMES_MEMORY_DIR}/overflow" 2>/dev/null | wc -l | tr -d ' ')

    local ts; ts=$(date '+%Y-%m-%d %H:%M:%S')
    local report
    report=$(python3 -c "
import json
print(json.dumps({
    'enabled': True,
    'timestamp': '$ts',
    'last_cycle': '$ts',
    'memory_free_mb': $free_mb,
    'memory_total_mb': $total_mb,
    'memory_used_pct': $used_pct,
    'mcp_process_count': $mcp_count,
    'tool_process_count': $tool_count,
    'skill_count': int('$skill_count'),
    'channel_count': int('$channel_count'),
    'moa_enabled': $( [[ "$HERMES_MOA_ENABLED" == "true" ]] && echo 'True' || echo 'False' ),
    'memory_tiers': {
        'instant': int('$mem_instant'),
        'session': int('$mem_session'),
        'overflow': int('$mem_overflow')
    }
}, indent=2))
")
    echo "$report"
    mkdir -p "$(dirname "$HERMES_HEALTH_REPORT_FILE")"
    echo "$report" > "$HERMES_HEALTH_REPORT_FILE"
}

# ── MoA (Mixture of Agents) ─────────────────────────────────────────────────

hermes_moa_analyze() {
    local prompt="$1"
    [[ "$HERMES_MOA_ENABLED" != "true" ]] && { call_llm "$prompt"; return; }
    [[ -z "$HERMES_MOA_MODELS" ]] && { call_llm "$prompt"; return; }

    load_api_config
    local tmpdir; tmpdir=$(mktemp -d /tmp/hermes-moa-XXXXXX)
    local pids=() models=()

    IFS=',' read -ra models <<< "$HERMES_MOA_MODELS"
    for model in "${models[@]}"; do
        model="${model#"${model%%[![:space:]]*}"}"
        model="${model%"${model##*[![:space:]]}"}"
        (
            SUMMARY_MODEL="$model" call_llm "$prompt" 2048 > "${tmpdir}/${model//\//_}.txt" 2>/dev/null
        ) &
        pids+=($!)
    done

    for pid in "${pids[@]}"; do
        wait "$pid" 2>/dev/null
    done

    local success=0 combined=""
    for f in "${tmpdir}"/*.txt; do
        [[ ! -f "$f" ]] && continue
        local content; content=$(cat "$f")
        if [[ -n "$content" && "$content" != *"summarization failed"* ]]; then
            success=$(( success + 1 ))
            local model_name; model_name=$(basename "$f" .txt | tr '_' '/')
            combined="${combined}
--- Response from ${model_name} ---
${content}
"
        fi
    done

    rm -rf "$tmpdir"

    if (( success < HERMES_MOA_MIN_SUCCESS )); then
        log_warn "HERMES: MoA failed — only $success/${#models[@]} models succeeded"
        call_llm "$prompt"
        return
    fi

    log_info "HERMES: MoA aggregating $success responses"
    call_llm "You are an expert synthesizer. Below are $success independent analyses of the same question. Produce a single, unified, high-quality response that takes the best from each.

$combined

Synthesize into one concise, authoritative response. Resolve any contradictions by favoring the most detailed/accurate answer."
}

# ── Memory Tiers ─────────────────────────────────────────────────────────────

hermes_memory_write() {
    local tier="$1" key="$2" content="$3"
    local dir="${HERMES_MEMORY_DIR}/${tier}"
    mkdir -p "$dir"
    case "$tier" in
        instant)
            local tmp; tmp=$(mktemp "${dir}/.${key}.XXXXXX")
            echo "$content" > "$tmp" && mv "$tmp" "${dir}/${key}"
            ;;
        session)
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] $content" >> "${dir}/${key}.log"
            local size; size=$(stat -f%z "${dir}/${key}.log" 2>/dev/null || echo 0)
            if (( size > 1048576 )); then
                mv "${dir}/${key}.log" "${HERMES_MEMORY_DIR}/overflow/${key}-$(date +%Y%m%d%H%M%S).log"
                log_debug "HERMES: Memory overflow archived ${key}.log"
            fi
            ;;
        overflow)
            echo "$content" > "${dir}/${key}"
            ;;
    esac
}

hermes_memory_read() {
    local tier="$1" key="$2"
    local dir="${HERMES_MEMORY_DIR}/${tier}"
    case "$tier" in
        instant)  [[ -f "${dir}/${key}" ]] && cat "${dir}/${key}" ;;
        session)  [[ -f "${dir}/${key}.log" ]] && tail -50 "${dir}/${key}.log" ;;
        overflow) [[ -f "${dir}/${key}" ]] && cat "${dir}/${key}" ;;
    esac
}

# ── Brain Inject — auto-write brain into project CLAUDE.md ────────────────────

hermes_list_projects() {
    local smart_home="$HOME/billion-smart"
    for d in "$smart_home"/*/brain; do
        [[ -d "$d" ]] || continue
        local proj; proj=$(basename "$(dirname "$d")")
        [[ "$proj" == ".venv" || "$proj" == "pageindex-workspace" ]] && continue
        echo "$proj"
    done
}

hermes_inject_brain() {
    local project="$1"
    local smart_home="$HOME/billion-smart"
    local brain_dir="${smart_home}/${project}/brain"

    if [[ ! -d "$brain_dir" ]]; then
        echo "Error: no brain found for project '$project'"
        echo "Available projects:"
        hermes_list_projects | sed 's/^/  /'
        return 1
    fi

    # Find the actual project directory on disk
    local project_dir=""
    case "$project" in
        _global)       project_dir="$HOME" ;;
        devin)         project_dir="$HOME/devin" ;;
        ai-watchdog)   project_dir="$HOME/ai-watchdog" ;;
        orba-desktop)  project_dir="$HOME/orba-desktop" ;;
        orba-memorybank-cli) project_dir="$HOME/orba-memorybank-cli" ;;
        *)             project_dir="$HOME/$project" ;;
    esac

    if [[ ! -d "$project_dir" ]]; then
        echo "Error: project directory not found: $project_dir"
        return 1
    fi

    # Collect brain content
    local brain_content=""
    local ts; ts=$(date '+%Y-%m-%d %H:%M')

    brain_content="# Project Brain — ${project}
> Auto-injected by ai-watchdog Hermes on ${ts}
> Source: ~/billion-smart/${project}/brain/
"

    for f in index.md user-focus.md learnings.md; do
        local fp="${brain_dir}/${f}"
        if [[ -f "$fp" ]] && [[ -s "$fp" ]]; then
            brain_content="${brain_content}
---

$(cat "$fp")
"
        fi
    done

    # Write to CLAUDE.md (append or create)
    local target="${project_dir}/CLAUDE.md"
    local marker="<!-- ai-watchdog-brain-start -->"
    local marker_end="<!-- ai-watchdog-brain-end -->"

    if [[ -f "$target" ]] && grep -q "$marker" "$target" 2>/dev/null; then
        # Replace existing brain section
        python3 -c "
import sys
content = open('$target').read()
start = content.find('$marker')
end = content.find('$marker_end')
if start >= 0 and end >= 0:
    new = content[:start] + sys.stdin.read() + content[end+len('$marker_end'):]
    open('$target', 'w').write(new)
    print('Updated brain section in $target')
else:
    open('$target', 'a').write('\n' + sys.stdin.read())
    print('Appended brain to $target')
" <<< "${marker}
${brain_content}
${marker_end}"
    else
        # Append to existing or create new
        {
            [[ -f "$target" ]] && echo ""
            echo "$marker"
            echo "$brain_content"
            echo "$marker_end"
        } >> "$target"
        echo "Injected brain into $target"
    fi

    log_info "HERMES: Brain injected for $project -> $target"
}

# ── Archive ──────────────────────────────────────────────────────────────────

hermes_archive_project() {
    local project="$1"
    local smart_home="$HOME/billion-smart"
    local proj_dir="${smart_home}/${project}"
    local archive_dir="${smart_home}/.archive/${project}-$(date +%Y%m%d)"

    [[ ! -d "$proj_dir" ]] && { log_warn "HERMES: Cannot archive — $proj_dir not found"; return 1; }
    [[ "$project" == "_global" ]] && { log_warn "HERMES: Refusing to archive _global"; return 1; }

    mkdir -p "$archive_dir"
    [[ -d "${proj_dir}/brain" ]] && cp -r "${proj_dir}/brain" "${archive_dir}/"
    [[ -d "${proj_dir}/summaries" ]] && cp -r "${proj_dir}/summaries" "${archive_dir}/"
    rm -f "${proj_dir}/summaries/"*.md 2>/dev/null
    echo "Archived on $(date '+%Y-%m-%d %H:%M') by Hermes agent" > "${proj_dir}/brain/.archived"
    log_info "HERMES: Archived $project to ${archive_dir}"
}

# ── Agent System Prompt ──────────────────────────────────────────────────────

# ── 10-min realtime agent: inject / refresh / alert only ─────────────────────

HERMES_AGENT_SYSTEM_PROMPT='You are Hermes, the intelligent guardian of an AI developer'\''s knowledge system.
You run every 10 minutes for REALTIME decisions only. Heavy work (archive, reindex) runs at midnight separately.

## Available Actions (realtime only)

| Action | Format | When to use |
|--------|--------|-------------|
| inject | {"action":"inject","project":"NAME","reason":"..."} | Brain has real content (brain_bytes > 200) AND CLAUDE.md is stale (>2h) or missing |
| refresh_brains | {"action":"refresh_brains","reason":"..."} | Brain files are empty but recent sessions have data to extract |
| generate_summaries | {"action":"generate_summaries","reason":"..."} | Recent sessions exist without summaries |
| alert | {"action":"alert","message":"...","reason":"..."} | Critical: memory_used_pct > 90 OR mcp_process_count > 20 |
| noop | {"action":"noop","reason":"..."} | Everything looks fine |

## Rules (STRICT)
1. PREFER noop. Only act when there is a clear, specific reason.
2. Do NOT inject if brain_bytes < 200.
3. Do NOT refresh_brains if there are no recent sessions.
4. Do NOT repeat the same action for the same project within 3 cycles (check LAST AGENT DECISIONS).
5. Maximum 3 actions per cycle.
6. You do NOT handle archive or reindex — those run at midnight.

## Output
ONLY a JSON array. No markdown fences, no explanation.
If nothing to do: [{"action":"noop","reason":"all systems nominal"}]'

# ── Midnight nightly agent: quality review + archive + reindex ────────────────

HERMES_NIGHTLY_SYSTEM_PROMPT='You are Hermes running the NIGHTLY REVIEW at midnight.
Your job: assess knowledge quality across ALL projects, decide what to archive, and trigger a full PageIndex reindex.

This runs ONCE per day. Be thorough.

## Compound Engineering Loop Context
The developer'\''s workflow follows this cycle:
  After every task → What worked? (→ learnings.md) → What failed? (→ anti-patterns) → What would I do differently? (→ CLAUDE.md)
Your job is to make sure this loop is working: brains are populated, summaries are fresh, stale projects are archived, and PageIndex is up to date.

## Available Actions

| Action | Format | When to use |
|--------|--------|-------------|
| archive | {"action":"archive","project":"NAME","reason":"..."} | Project dormant 7+ days AND score < 20 AND zero recent sessions. NEVER archive _global. |
| reindex | {"action":"reindex","reason":"..."} | Always run at midnight to keep PageIndex fresh |
| refresh_brains | {"action":"refresh_brains","reason":"..."} | Any project has empty brain files but has session data |
| generate_summaries | {"action":"generate_summaries","reason":"..."} | Any project has unsummarized sessions |
| inject | {"action":"inject","project":"NAME","reason":"..."} | High-value project (score>50) with stale CLAUDE.md |
| noop | {"action":"noop","reason":"..."} | Only if literally everything is perfect |

## Rules
1. ALWAYS include reindex as the LAST action (midnight is the time to reindex).
2. Archive conservatively — only truly dormant projects with no value.
3. NEVER archive _global.
4. Review each project individually in the KNOWLEDGE DIGEST and give a quality verdict.
5. Maximum 8 actions.

## Output
ONLY a JSON array. Include a brief quality assessment in each reason.'

# ── Context Collector ────────────────────────────────────────────────────────

hermes_collect_context() {
    local context=""

    # 1. Health
    local health; health=$(hermes_health_report 2>/dev/null)
    context="${context}
## HEALTH REPORT
${health}
"

    # 2. Knowledge digest
    local digest; digest=$(echo '{"days":7}' | bash "${HERMES_SKILLS_DIR}/daily-digest/skill.sh" 2>/dev/null)
    context="${context}
## KNOWLEDGE DIGEST (7 days)
${digest}
"

    # 3. Session activity
    local sessions; sessions=$(scan_recent_sessions 2>/dev/null | head -10)
    context="${context}
## RECENT SESSION ACTIVITY
${sessions:-No recent sessions.}
"

    # 4. Brain + CLAUDE.md status per project
    local brain_status="" smart_home="$HOME/billion-smart"
    for proj in $(hermes_list_projects 2>/dev/null); do
        local brain_dir="${smart_home}/${proj}/brain"
        local project_dir=""
        case "$proj" in
            _global) project_dir="$HOME" ;;
            *)       project_dir="$HOME/$proj" ;;
        esac
        local claude_md="${project_dir}/CLAUDE.md"
        local brain_bytes=0 brain_empty=0 brain_total=0

        for f in index.md user-focus.md learnings.md; do
            [[ -f "${brain_dir}/${f}" ]] || continue
            brain_total=$(( brain_total + 1 ))
            local sz; sz=$(stat -f%z "${brain_dir}/${f}" 2>/dev/null || echo 0)
            if (( sz == 0 )); then brain_empty=$(( brain_empty + 1 ))
            else brain_bytes=$(( brain_bytes + sz )); fi
        done

        local claude_md_age="missing" has_brain="false"
        if [[ -f "$claude_md" ]]; then
            local age_sec=$(( $(date +%s) - $(stat -f%m "$claude_md" 2>/dev/null || echo 0) ))
            if (( age_sec < 3600 )); then claude_md_age="${age_sec}s"
            elif (( age_sec < 86400 )); then claude_md_age="$(( age_sec / 3600 ))h"
            else claude_md_age="$(( age_sec / 86400 ))d"; fi
            grep -q "ai-watchdog-brain-start" "$claude_md" 2>/dev/null && has_brain="true"
        fi

        brain_status="${brain_status}
- ${proj}: brain_files=${brain_total} empty=${brain_empty} brain_bytes=${brain_bytes} claude_md=${claude_md_age} has_injected_brain=${has_brain}"
    done
    context="${context}
## BRAIN + CLAUDE.MD STATUS
${brain_status}
"

    # 5. Last decisions
    local last=""
    [[ -f "${HERMES_AGENT_DECISION_LOG:-/dev/null}" ]] && last=$(tail -15 "$HERMES_AGENT_DECISION_LOG" 2>/dev/null)
    context="${context}
## LAST AGENT DECISIONS
${last:-No previous decisions.}
"
    echo "$context"
}

# ── Action Executor ──────────────────────────────────────────────────────────

hermes_execute_agent_actions() {
    local llm_response="$1"
    local ts; ts=$(date '+%Y-%m-%d %H:%M:%S')

    local actions_json
    actions_json=$(python3 -c "
import json, sys, re
raw = sys.stdin.read().strip()
raw = re.sub(r'^\`\`\`json?\s*', '', raw)
raw = re.sub(r'\s*\`\`\`$', '', raw)
try:
    actions = json.loads(raw)
    if not isinstance(actions, list): actions = [actions]
    valid = [a for a in actions[:${HERMES_AGENT_MAX_ACTIONS:-5}] if isinstance(a, dict) and 'action' in a]
    print(json.dumps(valid))
except:
    print('[]')
    sys.exit(1)
" <<< "$llm_response")

    if [[ "$actions_json" == "[]" ]]; then
        log_info "HERMES AGENT: No valid actions parsed"
        echo "[${ts}] PARSE_FAIL: ${llm_response:0:300}" >> "${HERMES_AGENT_DECISION_LOG}"
        return
    fi

    echo "[${ts}] DECISIONS: ${actions_json}" >> "${HERMES_AGENT_DECISION_LOG}"

    python3 -c "
import json, sys
for a in json.loads(sys.stdin.read()):
    print(a.get('action','') + '\t' + a.get('project','') + '\t' + a.get('reason','') + '\t' + a.get('message',''))
" <<< "$actions_json" | while IFS=$'\t' read -r action project reason message; do
        [[ -z "$action" ]] && continue
        log_info "HERMES AGENT: → $action${project:+ ($project)} — $reason"

        case "$action" in
            inject)
                [[ -n "$project" ]] && hermes_inject_brain "$project" 2>/dev/null
                ;;
            refresh_brains)
                curl -s --max-time 30 -X POST "http://127.0.0.1:7474/api/refresh-brains" >/dev/null 2>&1 || \
                    log_warn "HERMES AGENT: refresh_brains failed (web server not running?)"
                ;;
            generate_summaries)
                generate_summary 2>/dev/null
                ;;
            reindex)
                run_pageindex_reindex 2>/dev/null
                ;;
            archive)
                [[ -n "$project" ]] && hermes_archive_project "$project" 2>/dev/null
                ;;
            alert)
                hermes_notify_all "Hermes Agent Alert" "${message:-${reason}}"
                ;;
            noop)
                log_info "HERMES AGENT: noop — $reason"
                ;;
            *)
                log_warn "HERMES AGENT: Unknown action '$action'"
                ;;
        esac
    done

    hermes_memory_write "instant" "last-agent-decisions" "$actions_json"
}

# ── Agent Loop ───────────────────────────────────────────────────────────────

hermes_agent_loop() {
    log_info "HERMES AGENT: Collecting context..."
    local context; context=$(hermes_collect_context 2>/dev/null)

    if [[ -z "$context" ]]; then
        log_warn "HERMES AGENT: Context collection failed, falling back"
        hermes_basic_cycle
        return
    fi

    load_api_config

    if [[ -z "$OPENAI_API_KEY" ]]; then
        log_warn "HERMES AGENT: No API key, falling back to basic cycle"
        hermes_basic_cycle
        return
    fi

    log_info "HERMES AGENT: Asking LLM for decisions..."
    local response
    response=$(call_llm_raw "$HERMES_AGENT_SYSTEM_PROMPT" "System state as of $(date '+%Y-%m-%d %H:%M:%S'):

${context}

What actions should I take? Output JSON array." 1024 2>/dev/null)

    if [[ -z "$response" || "$response" == *"summarization failed"* ]]; then
        log_warn "HERMES AGENT: LLM failed, falling back"
        hermes_basic_cycle
        return
    fi

    log_info "HERMES AGENT: Executing decisions..."
    hermes_execute_agent_actions "$response"
}

# ── Nightly Review (runs at ~midnight) ───────────────────────────────────────

hermes_nightly_review() {
    log_info "HERMES NIGHTLY: Starting midnight knowledge review..."

    load_api_config
    if [[ -z "$OPENAI_API_KEY" ]]; then
        log_warn "HERMES NIGHTLY: No API key, running basic reindex only"
        run_pageindex_reindex 2>/dev/null || true
        return
    fi

    local context; context=$(hermes_collect_context 2>/dev/null)
    if [[ -z "$context" ]]; then
        log_warn "HERMES NIGHTLY: Context failed, running basic reindex"
        run_pageindex_reindex 2>/dev/null || true
        return
    fi

    log_info "HERMES NIGHTLY: Asking LLM for nightly review..."
    local response
    response=$(call_llm_raw "$HERMES_NIGHTLY_SYSTEM_PROMPT" "Nightly review at $(date '+%Y-%m-%d %H:%M:%S'):

${context}

Perform the nightly knowledge quality review. Output JSON array of actions." 2048 2>/dev/null)

    if [[ -z "$response" || "$response" == *"summarization failed"* ]]; then
        log_warn "HERMES NIGHTLY: LLM failed, running basic reindex"
        run_pageindex_reindex 2>/dev/null || true
        return
    fi

    log_info "HERMES NIGHTLY: Executing nightly actions..."
    hermes_execute_agent_actions "$response"

    # Always reindex at midnight even if LLM didn't ask
    log_info "HERMES NIGHTLY: Ensuring PageIndex reindex..."
    run_pageindex_reindex 2>/dev/null || true

    # Daily skill usage report
    log_info "HERMES NIGHTLY: Generating daily skill usage report..."
    local tracker_result
    tracker_result=$(echo '{"hours":24}' | bash "${HERMES_SKILLS_DIR}/skill-tracker/skill.sh" 2>/dev/null)
    if [[ -n "$tracker_result" ]]; then
        hermes_memory_write "instant" "daily-skill-report" "$tracker_result"
        hermes_memory_write "session" "skill-tracker" "$tracker_result"

        # Save as readable markdown
        local report_dir="${HOME}/billion-smart/_global/reports"
        mkdir -p "$report_dir"
        python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
lines = ['# Daily Tool Usage — $(date "+%Y-%m-%d")', '']
lines.append(f'Sessions: {d[\"sessions_scanned\"]} | Messages: {d[\"total_messages\"]} | Tool calls: {d[\"total_tool_calls\"]}')
lines.append('')
lines.append('## Top 5 Tools')
for t in d.get('top_5', []):
    lines.append(f'### {t[\"tool\"]} ({t[\"count\"]} calls)')
    lines.append(f'> {t[\"suggestion\"]}')
    if t.get('top_projects'):
        lines.append('Projects: ' + ', '.join(f'{p[\"project\"]} ({p[\"count\"]})' for p in t['top_projects']))
    lines.append('')
lines.append('## Patterns')
for p in d.get('patterns', []):
    lines.append(f'- {p}')
lines.append('')
lines.append('---')
lines.append('_Generated by ai-watchdog skill-tracker_')
print('\n'.join(lines))
" <<< "$tracker_result" > "${report_dir}/skill-report-$(date +%Y%m%d).md" 2>/dev/null
        log_info "HERMES NIGHTLY: Skill report saved"
    fi

    log_info "HERMES NIGHTLY: Review complete"
}

# ── Basic Cycle (fallback, no LLM) ──────────────────────────────────────────

hermes_basic_cycle() {
    local report; report=$(hermes_health_report)
    hermes_memory_write "instant" "last-health" "$report"
    hermes_memory_write "session" "health-history" "$report"

    local used_pct; used_pct=$(echo "$report" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('memory_used_pct',0))" 2>/dev/null)
    local mcp_count; mcp_count=$(echo "$report" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('mcp_process_count',0))" 2>/dev/null)

    local anomalies=""
    (( used_pct > 85 )) && anomalies="${anomalies}High memory: ${used_pct}%. "
    (( mcp_count > 15 )) && anomalies="${anomalies}MCP swarm: ${mcp_count}. "

    if [[ -n "$anomalies" ]]; then
        log_warn "HERMES: Anomalies — $anomalies"
        hermes_notify_all "Watchdog Alert" "$anomalies"
    fi
}

# ── Periodic Hermes Cycle (dispatcher) ───────────────────────────────────────

run_hermes_cycle() {
    [[ "$HERMES_ENABLED" != "true" ]] && return 0

    HERMES_LAST_CYCLE=$(( HERMES_LAST_CYCLE + 1 ))
    (( HERMES_LAST_CYCLE % HERMES_CYCLE_INTERVAL != 0 )) && return 0

    log_info "HERMES: Cycle #${HERMES_LAST_CYCLE}"

    if [[ "$HERMES_AGENT_ENABLED" == "true" ]]; then
        hermes_agent_loop
    else
        hermes_basic_cycle
    fi
}

# ── Initialize on source ────────────────────────────────────────────────────
hermes_load_channels || true
