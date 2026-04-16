#!/usr/bin/env bash
set -euo pipefail
PLIST_NAME="com.ai-watchdog.agent"
PLIST_FILE="$HOME/Library/LaunchAgents/${PLIST_NAME}.plist"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PID_FILE="${SCRIPT_DIR}/logs/watchdog.pid"

echo "=== AI Watchdog Uninstall ==="
[[ -f "$PLIST_FILE" ]] && { launchctl unload "$PLIST_FILE" 2>/dev/null; rm -f "$PLIST_FILE"; echo "  Removed LaunchAgent"; }
[[ -f "$PID_FILE" ]] && { pid=$(cat "$PID_FILE"); kill "$pid" 2>/dev/null || true; rm -f "$PID_FILE"; }
echo "  Done. Logs preserved in ${SCRIPT_DIR}/logs/"
