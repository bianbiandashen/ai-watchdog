# ai-watchdog 🔎

**7×24 process guardian for Claude · Codex · Cursor · Orba on macOS**

> Woke up this morning to find my Mac had 339 MB of free memory left — down from 48 GB — because 310 orphaned `server-qdrant.js` MCP server processes had silently eaten 16 GB overnight.  
> `ai-watchdog` makes sure that never happens again.

---

## The Problem

Every time you start a Claude Code / Codex / Cursor / Orba session, these tools spawn **MCP server child processes**. When the parent session crashes or exits abnormally, the children keep running forever — consuming gigabytes of RAM, burning CPU, and eventually making the machine unusable.

```
Morning discovery:
  Orphan server-qdrant.js:  310 processes  →  16.4 GB RAM
  System free memory:                       →  339 MB
  Result:                                   →  Mac grinding halt
```

### What ai-watchdog does

| Capability | How |
|---|---|
| **Orphan reaper** | Scans every 30 s, kills MCP server procs whose parent died |
| **Swarm detection** | Kills extras when N copies of the same MCP server exceed threshold |
| **Memory guard** | Emergency cleanup when free RAM < 512 MB |
| **Log janitor** | Deletes `debug-*.log` files older than 3 days from `.orba`, `.codex`, `.claude` |
| **Session recovery** | Lists last 5 sessions each for Claude and Codex, prints resume command |
| **Live TUI** | ANSI dashboard refreshing every 3 s — memory bars, process counts, log tail |
| **LaunchAgent** | Starts on login via launchd, restarts automatically if it crashes |
| **Never kills CLI** | `claude`, `codex`, `Cursor`, `OrbaDesktop`, `Warp` — all protected |

---

## Sequence Diagrams

### 1 · Orphan Accumulation (the problem this solves)

```mermaid
sequenceDiagram
    participant User
    participant Claude as Claude CLI
    participant MCP as MCP Server (server-qdrant.js)
    participant OS as macOS

    User->>Claude: claude --resume <session>
    Claude->>MCP: spawn child process
    MCP-->>OS: register in process table (PPID=Claude PID)

    Note over User,Claude: Session crashes / is killed abnormally

    Claude->>OS: process exits (abnormal)
    Note over MCP,OS: PPID becomes 1 (launchd)<br/>MCP server is now an orphan

    loop every new session
        User->>Claude: start new session
        Claude->>MCP: spawn another MCP server
        Note over MCP: Previous orphan still running!
    end

    Note over MCP,OS: 310 orphans × 53 MB = 16.4 GB consumed
    OS-->>User: system grinds to halt (339 MB free)
```

---

### 2 · Watchdog Normal Cycle

```mermaid
sequenceDiagram
    participant WD as ai-watchdog daemon
    participant PS as ps aux
    participant MCP as Orphan MCP procs
    participant LOG as Log / State file
    participant NOTIFY as macOS Notifications

    loop every 30 seconds
        WD->>PS: scan ORPHAN_TARGET_PATTERNS
        PS-->>WD: process list with PPID

        alt orphan found (PPID=1 or parent dead)
            WD->>MCP: SIGTERM
            WD->>LOG: log "KILL PID=xxx"
            MCP-->>WD: process exits
            WD->>NOTIFY: "Killed N orphans, freed XMB"
        else swarm detected (count > threshold)
            WD->>MCP: kill oldest extras (keep 2)
            WD->>LOG: log "swarm cleanup"
        else all clean
            WD->>LOG: log "Memory OK: NMB free"
        end

        WD->>LOG: write state.json (for TUI)
    end
```

---

### 3 · Memory Pressure Emergency

```mermaid
sequenceDiagram
    participant WD as ai-watchdog
    participant VM as vm_stat
    participant MCP as MCP Servers
    participant LOG as Snapshot

    WD->>VM: get_free_mem_mb()
    VM-->>WD: 250 MB (< CRITICAL 512 MB)

    WD->>LOG: save_snapshot() — diagnostic dump
    WD->>WD: emergency_cleanup()

    loop for each ORPHAN_TARGET_PATTERN
        WD->>MCP: kill -9 all instances
    end

    WD->>VM: get_free_mem_mb()
    VM-->>WD: 22000 MB (freed!)
    WD->>WD: notify "Emergency done. 22GB freed."
```

---

### 4 · Session Recovery Flow

```mermaid
sequenceDiagram
    participant User
    participant WD as watchdog.sh recover
    participant FS as ~/.claude/projects/
    participant FS2 as ~/.codex/history.jsonl

    User->>WD: ./watchdog.sh recover

    WD->>FS: find *.jsonl, sort by mtime
    FS-->>WD: session list (filename=sessionId)
    WD->>WD: extract first user message as summary

    WD->>FS2: parse history.jsonl
    FS2-->>WD: unique session_ids sorted by ts

    WD-->>User: display table (last 5 each)
    Note over User,WD: c1 04/16 13:48  /Users/...  "help me debug..."
    Note over User,WD: d1 04/16 11:23  ~/project   "refactor auth..."

    User->>WD: enter "c1"
    WD-->>User: claude --resume 45a7ec54-4a20-4c7f-...
    User->>User: run command in terminal
```

---

### 5 · TUI Live Dashboard Loop

```mermaid
sequenceDiagram
    participant User
    participant TUI as tui.sh
    participant WD as watchdog daemon
    participant STATE as logs/state.json

    User->>TUI: ./tui.sh
    TUI->>TUI: hide cursor, enter alt screen

    loop every TUI_REFRESH (3s)
        TUI->>STATE: read daemon stats
        TUI->>TUI: vm_stat → memory bar
        TUI->>TUI: ps aux → process counts
        TUI->>TUI: tail -8 logs/watchdog.log
        TUI-->>User: render full dashboard
        TUI->>User: non-blocking key read (3s timeout)
    end

    alt key=q
        TUI->>User: restore terminal, exit
    else key=c
        TUI->>WD: cleanup_orphans() + cleanup_memory_hogs()
    else key=r
        TUI->>User: show recovery menu (interactive)
    else key=s
        TUI->>TUI: save_snapshot()
    end
```

---

### 6 · launchd Auto-Start & Keep-Alive

```mermaid
sequenceDiagram
    participant Boot as macOS Login
    participant LD as launchd
    participant WD as watchdog.sh
    participant PLIST as LaunchAgent plist

    Boot->>LD: user login
    LD->>PLIST: read com.ai-watchdog.agent.plist
    PLIST-->>LD: RunAtLoad=true, KeepAlive=true

    LD->>WD: spawn watchdog.sh run

    Note over LD,WD: watchdog runs 7×24

    alt watchdog crashes or exits
        LD->>WD: restart automatically (KeepAlive)
        Note over LD,WD: ThrottleInterval=30s prevents tight respawn loop
    end
```

---

## Installation

```bash
git clone git@github.com:bianbiandashen/ai-watchdog.git ~/ai-watchdog
cd ~/ai-watchdog
./install.sh
```

That's it. The watchdog starts immediately and survives reboots.

## Usage

| Command | What it does |
|---|---|
| `./tui.sh` | Open live ANSI dashboard |
| `./status.sh` | Quick one-shot status print |
| `./watchdog.sh clean` | Manually run all cleanups now |
| `./watchdog.sh recover` | Interactive session recovery menu |
| `./watchdog.sh snapshot` | Save diagnostic snapshot to `logs/snapshots/` |
| `./uninstall.sh` | Stop daemon and remove LaunchAgent |

## Configuration

All thresholds live in `config.sh`:

```bash
CHECK_INTERVAL=30              # scan every 30 seconds
SYSTEM_MEM_MIN_FREE_MB=2048    # warn + cleanup when free < 2 GB
SYSTEM_MEM_CRITICAL_MB=512     # emergency kill when free < 512 MB
PROCESS_MEM_MAX_MB=4096        # kill single proc exceeding 4 GB
ORPHAN_THRESHOLD=2             # keep at most 2 instances of each MCP server
LOG_MAX_AGE_DAYS=3             # delete debug logs older than 3 days
```

### What gets killed vs. protected

**Only these patterns are eligible for killing** (`ORPHAN_TARGET_PATTERNS`):
- `server-qdrant.js` — Qdrant MCP server
- `orba-context-mcp` / `orba-context@` — Orba MCP servers
- `figma.*mcp`, `mitmproxy.*mcp`, `playwright.*mcp`, etc.

**These are NEVER touched** (`NEVER_KILL_PATTERNS`):
- `claude`, `codex` — CLI tools (your active sessions)
- `Cursor`, `OrbaDesktop`, `Warp` — GUI apps
- Any process matching `claude.*--dangerously` — active Claude Code sessions

## Project Structure

```
ai-watchdog/
├── watchdog.sh          # Main daemon + CLI dispatcher
├── tui.sh               # Live ANSI terminal dashboard
├── status.sh            # Quick one-shot status
├── install.sh           # launchd LaunchAgent installer
├── uninstall.sh         # Remove LaunchAgent
├── config.sh            # All thresholds and patterns
├── lib/
│   ├── utils.sh         # Logging, notify, memory helpers, safe_kill
│   ├── monitor.sh       # Orphan detection, memory pressure, snapshots
│   ├── cleanup.sh       # Kill routines: orphans, hogs, emergency, logs
│   └── recovery.sh      # Session list parser and resume helper
└── logs/                # watchdog.log, state.json, snapshots/ (gitignored)
```

## Requirements

- macOS 12+ (uses `launchctl`, `vm_stat`, `osascript`)
- Bash 5+ (`brew install bash` if needed)
- Python 3 (pre-installed on macOS, used for JSON parsing in recovery)

## License

MIT
