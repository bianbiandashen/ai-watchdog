# Best Practices from EveryInc/compound-engineering-plugin

> Source: https://github.com/EveryInc/compound-engineering-plugin (14.5k stars)
> "Each unit of engineering work should make subsequent units easier."

## The Compound Loop (THE differentiator)

```
Brainstorm -> Plan -> Work -> Review -> COMPOUND -> Repeat
```

The **Compound** step is what most workflows skip — explicitly capture what you learned and encode it for reuse. This is why the plugin is called "compound" engineering.

## 80/20 Inverted

- 80% of time on **planning and review**
- 20% on **execution**
- AI makes execution cheap; the bottleneck is knowing WHAT to build

## Key Patterns to Copy into CLAUDE.md

```markdown
# Add to CLAUDE.md:

## Instruction File Convention
- AGENTS.md is canonical (works across all AI tools)
- CLAUDE.md is a one-line shim: `See @AGENTS.md for all instructions`
- This prevents instruction drift across Claude/Codex/Cursor/Orba

## Docs Structure (4-category lifecycle)
docs/
├── brainstorms/    # Early-stage ideas (throwaway OK)
├── plans/          # Committed plans (must be reviewed)
├── specs/          # Technical specifications (source of truth)
└── solutions/      # Implemented solutions (categorized by audience)

## Scratch Space Conventions
- `.context/<namespace>/` — inter-skill state (other skills may read)
- `mktemp -d` — throwaway artifacts (auto-cleaned)
- `docs/` — durable outputs (committed to git)

## Skill Design Rules
- Each skill must be self-contained (no cross-directory references)
- If two skills need the same file, duplicate it
- Use fully-qualified names: `plugin:category:skill-name`
- Commit prefix by INTENT not file type: `feat:` not `docs:` for skill changes
```

## Multi-Agent Review Pipeline

The `/ce:review` skill runs 25+ specialized review personas:
- Correctness reviewer
- Security reviewer  
- Performance reviewer
- Accessibility reviewer
- Then **deduplicates** findings

This is far more thorough than single-pass review. Pattern:
```bash
# In CLAUDE.md, add:
## Code Review Checklist (run ALL before merge)
1. Correctness: does it do what was asked?
2. Security: any injection, XSS, SSRF, auth bypass?
3. Performance: any N+1 queries, unbounded loops, memory leaks?
4. Edge cases: empty input, null, max values, concurrent access?
```

## Research Agents

Compound Engineering has agents that pull context from:
- Git history (what was tried before)
- GitHub issues (related discussions)
- Slack (team decisions)
- Session history (what you asked earlier)

This is the "organizational memory" pattern — always check what already exists before starting fresh.
