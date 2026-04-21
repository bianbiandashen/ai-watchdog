#!/usr/bin/env bash
# ai-watchdog configuration

WATCHDOG_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${WATCHDOG_HOME}/logs"
LOG_FILE="${LOG_DIR}/watchdog.log"
SNAPSHOT_DIR="${LOG_DIR}/snapshots"

# ─── Timing ──────────────────────────────────────────────────────────────────
CHECK_INTERVAL=30          # seconds between scan cycles
TUI_REFRESH=3              # seconds between TUI redraws

# ─── Memory thresholds ───────────────────────────────────────────────────────
SYSTEM_MEM_MIN_FREE_MB=2048   # warn + cleanup when free < this
SYSTEM_MEM_CRITICAL_MB=512    # emergency kill when free < this
PROCESS_MEM_MAX_MB=4096       # kill single process exceeding this (MB RSS)

# ─── Orphan swarm threshold ──────────────────────────────────────────────────
# If more than N instances of the same MCP pattern exist, extras are orphans
ORPHAN_THRESHOLD=2

# ─── Processes that are MCP servers / subprocesses (SAFE TO KILL if orphaned)
# These are the only processes that will be killed by the watchdog
ORPHAN_TARGET_PATTERNS=(
    'server-qdrant\.js'
    'orba-context-mcp'
    'orba-context@'
    'orba-context/dist/mcp'
    'figma.*mcp'
    'mitmproxy.*mcp'
    'playwright.*mcp'
    'ChromeDevTools.*mcp'
    'proxyman.*mcp'
    'plugin_miniprogram'
    'mp-cli.*mcp'
)

# ─── Processes to MONITOR but NEVER kill ─────────────────────────────────────
MONITOR_ONLY_PATTERNS=(
    'claude'
    'codex'
    'Cursor'
    'Warp'
    'OrbaDesktop'
    'orba-cli'
    'orba-desktop'
)

# ─── Processes that must NEVER be killed under any circumstance ───────────────
NEVER_KILL_PATTERNS=(
    '^claude$'
    'claude --'
    'claude.*--dangerously'
    '^codex$'
    'codex --'
    'Cursor$'
    'Cursor Helper \(GPU\)'
    'Cursor Helper \(Renderer\)'
    'Warp'
    '/Applications/OrbaDesktop'
    '/Applications/Cursor'
)

# ─── Log cleanup ─────────────────────────────────────────────────────────────
LOG_MAX_AGE_DAYS=3
LOG_DIR_MAX_SIZE_MB=500
LOG_SCAN_DIRS=(
    "$HOME/.orba"
    "$HOME/.codex"
    "$HOME/.claude"
)
LOG_CLEAN_PATTERNS=(
    'debug-*.log'
    'agent-debug.log'
)

# ─── Recovery ────────────────────────────────────────────────────────────────
RECOVERY_MAX_ATTEMPTS=3
RECOVERY_WINDOW_SEC=300

# ─── Notifications ───────────────────────────────────────────────────────────
NOTIFY_ENABLED=true
VERBOSE=false    # set to true to see DEBUG lines in watchdog.log

# ─── Hermes Agent ────────────────────────────────────────────────────────────
HERMES_ENABLED=true
HERMES_AGENT_ENABLED=true      # LLM-based agent decisions (requires API key in .env)
HERMES_CYCLE_INTERVAL=20       # every N daemon cycles (~10min at 30s interval)
HERMES_SKILLS_DIR="${WATCHDOG_HOME}/skills"
HERMES_MEMORY_DIR="${WATCHDOG_HOME}/memory"
HERMES_NOTIFY_CHANNELS=()      # populated at runtime from .env webhook URLs
HERMES_MOA_ENABLED=false        # Mixture-of-Agents parallel analysis
HERMES_MOA_MIN_SUCCESS=1        # minimum successful LLM responses for MoA aggregation
HERMES_HEALTH_REPORT_FILE="${LOG_DIR}/hermes-health.json"
HERMES_AGENT_DECISION_LOG="${HERMES_MEMORY_DIR}/session/agent-decisions.log"
HERMES_AGENT_MAX_ACTIONS=5     # safety cap on actions per cycle
HERMES_LAST_CYCLE=0
