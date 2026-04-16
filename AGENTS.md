# ai-watchdog — Agent Instructions

## What this project is
A 7×24 macOS daemon that monitors AI coding tools (Claude, Codex, Cursor, Orba, Warp), kills orphan MCP server processes, guards system memory, and provides session recovery.

## Architecture
- **Bash daemon** (`watchdog.sh`) runs via macOS LaunchAgent, scans every 30s
- **Shell libraries** (`lib/*.sh`) handle monitoring, cleanup, recovery, memory
- **Node.js web server** (`web/server.js`) provides REST API + SPA dashboard on port 7474
- **TUI** (`tui.sh`) ANSI terminal dashboard with keyboard controls

## Key rules
- NEVER kill CLI tools or GUI apps (claude, codex, Cursor, Warp, OrbaDesktop)
- ONLY kill MCP server subprocesses (patterns in `config.sh` → `ORPHAN_TARGET_PATTERNS`)
- Zero external dependencies for bash daemon; zero npm deps for web server
- `.env` contains API keys — NEVER commit it

## Docs structure
```
docs/
├── design-docs/          # Architecture decisions
├── exec-plans/active/    # Current implementation plans
├── exec-plans/completed/ # Done plans
├── generated/            # Auto-generated docs
├── product-specs/        # Feature specifications
├── references/           # External reference material
└── memory/
    ├── summaries/        # Auto-generated 30-min session summaries
    └── best-practices/   # Curated patterns from top repos
```

## Workflow
Follow the compound engineering pattern:
1. Brainstorm → 2. Plan → 3. Work → 4. Review → 5. **Compound** (capture learnings)
