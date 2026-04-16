# ai-watchdog

![macOS](https://img.shields.io/badge/macOS-12%2B-blue)
![Bash](https://img.shields.io/badge/bash-5%2B-green)
![Node.js](https://img.shields.io/badge/node-18%2B-green)
![License](https://img.shields.io/badge/license-MIT-blue)
![Zero Dependencies](https://img.shields.io/badge/deps-zero-brightgreen)

**7×24 process guardian for Claude · Codex · Cursor · Orba · Warp on macOS — kills orphan MCP servers, guards memory, recovers sessions.**

> Woke up to find my Mac had **339 MB free** out of 48 GB — because **310 orphaned `server-qdrant.js`** MCP processes silently ate **16.4 GB** overnight.
> `ai-watchdog` makes sure that never happens again.

---

## Screenshots

### Web Dashboard (`http://localhost:7474`)

![Web Dashboard](docs/screenshot-loaded.png)

### Terminal TUI (`./tui.sh`)

Live ANSI dashboard with memory bars, process tables, session recovery, and keyboard shortcuts.

---

## The Problem

Every time you start a Claude Code / Codex / Cursor / Orba session, these tools spawn **MCP server child processes** (Qdrant, Playwright, Figma, mitmproxy, Chrome DevTools, etc.). When the parent session crashes or exits abnormally, the children keep running forever — consuming gigabytes of RAM.

```
Morning discovery:
  Orphan server-qdrant.js:  310 processes  →  16.4 GB RAM
  System free memory:                       →  339 MB
  Result:                                   →  Mac grinding to halt
```

### What ai-watchdog does

| Capability | How |
|---|---|
| **Orphan reaper** | Scans every 30s, kills MCP server procs whose parent died (PPID=1) |
| **Swarm detection** | Kills extras when N copies of the same MCP server exceed threshold |
| **Memory guard** | Emergency cleanup when free RAM < 512 MB; "Clean to 60%" one-click |
| **Web dashboard** | Real-time browser UI on `localhost:7474` — kill any process, export sessions |
| **Live TUI** | ANSI terminal dashboard refreshing every 3s — memory bars, process counts |
| **Session recovery** | Lists last 5 sessions for Claude and Codex, prints resume command |
| **Log janitor** | Deletes `debug-*.log` older than 3 days from `.orba`, `.codex`, `.claude` |
| **LaunchAgent** | Starts on login via launchd, restarts automatically if it crashes |
| **Never kills CLI** | `claude`, `codex`, `Cursor`, `OrbaDesktop`, `Warp` — all protected |

---

## Alternatives Comparison

| Feature | ai-watchdog | mcp-orphan-monitor | mcp-cleanup | process-police | ccboard |
|---|:---:|:---:|:---:|:---:|:---:|
| Orphan detection & kill | **Yes** | Yes | Yes | Yes | No |
| Memory pressure guard | **Yes** | No | No | No | No |
| Web dashboard | **Yes** | No | No | No | Yes |
| Terminal TUI | **Yes** | No | No | Yes (Linux) | No |
| Session recovery | **Yes** | No | No | No | View only |
| launchd auto-start | **Yes** | Yes | Yes | No | No |
| macOS native | **Yes** | Yes | Yes | Linux only | Cross |
| Zero dependencies | **Yes** | No (Python) | Yes | No (Rust) | No (Rust) |

---

<details>
<summary><strong>Architecture — Sequence Diagrams (click to expand)</strong></summary>

### 1 · Orphan Accumulation (the problem)

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
        else all clean
            WD->>LOG: log "Memory OK: NMB free"
        end

        WD->>LOG: write state.json (for TUI/Web)
    end
```

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
    Note over User,WD: c1 04/16 13:48  "help me debug..."
    Note over User,WD: d1 04/16 11:23  "refactor auth..."

    User->>WD: enter "c1"
    WD-->>User: claude --resume 45a7ec54-...
```

### 5 · TUI Live Dashboard Loop

```mermaid
sequenceDiagram
    participant User
    participant TUI as tui.sh
    participant STATE as logs/state.json

    User->>TUI: ./tui.sh
    TUI->>TUI: hide cursor, enter alt screen

    loop every 3s
        TUI->>STATE: read daemon stats
        TUI->>TUI: vm_stat → memory bar
        TUI->>TUI: ps aux → process counts
        TUI-->>User: render full dashboard
    end

    alt key=q
        TUI->>User: restore terminal, exit
    else key=c
        TUI->>TUI: cleanup_orphans()
    else key=r
        TUI->>User: show recovery menu
    end
```

### 6 · launchd Auto-Start & Keep-Alive

```mermaid
sequenceDiagram
    participant Boot as macOS Login
    participant LD as launchd
    participant WD as watchdog.sh

    Boot->>LD: user login
    LD->>WD: spawn watchdog.sh run (RunAtLoad=true)

    Note over LD,WD: watchdog runs 7×24

    alt watchdog crashes
        LD->>WD: restart automatically (KeepAlive)
        Note over LD,WD: ThrottleInterval=30s prevents tight loop
    end
```

</details>

---

## Installation

```bash
git clone git@github.com:bianbiandashen/ai-watchdog.git ~/ai-watchdog
cd ~/ai-watchdog
./install.sh
```

That's it. The watchdog starts immediately and survives reboots.

### Web Dashboard (optional)

```bash
node web/server.js &
open http://localhost:7474
```

---

## Usage

| Command | What it does |
|---|---|
| `./tui.sh` | Open live ANSI dashboard |
| `node web/server.js` | Start web dashboard on port 7474 |
| `./status.sh` | Quick one-shot status print |
| `./watchdog.sh clean` | Manually run all cleanups now |
| `./watchdog.sh recover` | Interactive session recovery menu |
| `./watchdog.sh snapshot` | Save diagnostic snapshot |
| `./uninstall.sh` | Stop daemon and remove LaunchAgent |

---

## Configuration

All thresholds live in `config.sh`:

```bash
CHECK_INTERVAL=30              # scan every 30 seconds
SYSTEM_MEM_MIN_FREE_MB=2048    # warn + cleanup when free < 2 GB
SYSTEM_MEM_CRITICAL_MB=512     # emergency kill when free < 512 MB
PROCESS_MEM_MAX_MB=4096        # kill single proc exceeding 4 GB
ORPHAN_THRESHOLD=2             # keep at most 2 instances per MCP server
LOG_MAX_AGE_DAYS=3             # delete debug logs older than 3 days
```

### What gets killed vs. protected

**Only these MCP patterns are eligible for killing** (`ORPHAN_TARGET_PATTERNS`):
- `server-qdrant.js` — Qdrant Vector DB
- `orba-context-mcp` / `orba-context@` — Orba Context MCP servers
- `figma.*mcp`, `playwright.*mcp`, `ChromeDevTools.*mcp`, `mitmproxy.*mcp`, `proxyman.*mcp`
- `plugin_miniprogram`, `mp-cli.*mcp`

**These are NEVER touched** (`NEVER_KILL_PATTERNS`):
- `claude`, `codex` — CLI tools (your active sessions)
- `Cursor`, `OrbaDesktop`, `Warp` — GUI apps
- Any process matching `claude.*--dangerously` — active Claude Code sessions

---

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
├── web/
│   ├── server.js        # Node.js API server (zero deps, port 7474)
│   └── public/
│       └── index.html   # Single-file SPA dashboard
├── docs/                # Screenshots
└── logs/                # watchdog.log, state.json, snapshots/ (gitignored)
```

---

## Requirements

- macOS 12+ (uses `launchctl`, `vm_stat`, `osascript`)
- Bash 5+ (`brew install bash` if needed)
- Python 3 (pre-installed on macOS, used for JSON parsing in recovery)
- Node.js 18+ (optional, for web dashboard only)

---

## FAQ

**Will this kill my Claude / Codex session?**
No. All CLI tools and GUI apps are in the `NEVER_KILL_PATTERNS` list. Only MCP server subprocesses (Qdrant, Playwright, Figma MCP, etc.) are eligible.

**Does this work on Linux?**
Not yet — it uses macOS-specific APIs (`vm_stat`, `osascript`, `launchctl`). PRs welcome.

**How do I change the scan interval?**
Edit `CHECK_INTERVAL` in `config.sh`. Default is 30 seconds.

**What's the "Clean to 60%" button?**
It kills MCP processes biggest-first until system memory usage drops below 60%. The 80% red line on the gauge shows when you should start cleaning.

---

## Contributing

1. Fork the repo
2. Create a feature branch (`git checkout -b feat/my-feature`)
3. Keep the zero-dependency constraint (no npm packages for the bash daemon)
4. Test on macOS
5. Submit a PR

---

## License

[MIT](LICENSE)
