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
