#!/usr/bin/env bash
# Install ai-watchdog as macOS LaunchAgent (auto-start on login)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLIST_NAME="com.ai-watchdog.agent"
PLIST_FILE="$HOME/Library/LaunchAgents/${PLIST_NAME}.plist"

echo "=== AI Watchdog Installer ==="
echo ""

chmod +x "${SCRIPT_DIR}/watchdog.sh" "${SCRIPT_DIR}/tui.sh" \
         "${SCRIPT_DIR}/status.sh"   "${SCRIPT_DIR}/uninstall.sh"

# Generate plist
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST_FILE" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>          <string>${PLIST_NAME}</string>

    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${SCRIPT_DIR}/watchdog.sh</string>
        <string>run</string>
    </array>

    <key>RunAtLoad</key>      <true/>
    <key>KeepAlive</key>      <true/>
    <key>ThrottleInterval</key><integer>30</integer>

    <key>StandardOutPath</key>
    <string>${SCRIPT_DIR}/logs/launchd.out.log</string>
    <key>StandardErrorPath</key>
    <string>${SCRIPT_DIR}/logs/launchd.err.log</string>

    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin</string>
        <key>HOME</key>      <string>${HOME}</string>
        <key>LANG</key>      <string>en_US.UTF-8</string>
    </dict>

    <key>ProcessType</key>    <string>Background</string>
    <key>LowPriorityBackgroundIO</key><true/>
    <key>Nice</key>           <integer>10</integer>
</dict>
</plist>
EOF

# Unload existing
launchctl unload "$PLIST_FILE" 2>/dev/null || true

# Load
launchctl load "$PLIST_FILE"

echo "  Installed: $PLIST_FILE"
echo "  Logs:      ${SCRIPT_DIR}/logs/"
echo ""

sleep 2
if launchctl list | grep -q "$PLIST_NAME" 2>/dev/null; then
    echo "  Status:    RUNNING ✓"
else
    echo "  Status:    WARNING — check ${SCRIPT_DIR}/logs/launchd.err.log"
fi

echo ""
echo "Commands:"
echo "  ./tui.sh          Live dashboard"
echo "  ./status.sh       Quick status"
echo "  ./watchdog.sh recover   Session recovery menu"
echo "  ./uninstall.sh    Stop and remove"
