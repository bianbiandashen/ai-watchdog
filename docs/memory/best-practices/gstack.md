# Best Practices from garrytan/gstack

> Source: https://github.com/garrytan/gstack (Garry Tan / YC CEO)
> Virtual engineering team with 23+ specialized roles. 600k+ lines in 60 days.

## "Boil the Lake" Philosophy

When AI makes marginal cost of completeness near-zero, **always do the complete implementation**.
Don't take 90% shortcuts when 100% costs seconds more.
But distinguish "lakes" (achievable) from "oceans" (unrealistic scope).

## Search Before Building — 3 Knowledge Layers

1. **Layer 1:** Battle-tested standard patterns (highest trust)
2. **Layer 2:** Current best practices (deserve scrutiny)
3. **Layer 3:** First-principles reasoning (most valuable)

Always search: `"{runtime} {thing} built-in"` and `"{thing} best practice 2026"` before writing code.

## Key Patterns to Copy into CLAUDE.md

```markdown
# Add to CLAUDE.md:

## Code Philosophy
- Completeness is cheap. Do the full implementation, not 90%.
- Search before building: always check if a built-in exists first.
- AI recommends. User decides. Never skip human verification.
- Know compression ratios: scaffolding ~100x, architecture ~3-5x.

## AI Slop Scan
Actively catch these AI-generated code smells:
- Empty catch blocks
- Redundant `return await`
- Untyped exception handlers
- Unnecessary abstractions for one-time operations
- "Helpful" additions beyond what was asked

## Commit Style
- Branch-scoped CHANGELOG + VERSION
- Write changelogs for USERS, not contributors
- "Every entry should inspire someone to try the feature"

## E2E Blame Protocol
- Never claim a test failure is "pre-existing" without proof
- Run the same test on main first
- If you can't verify, say "unverified"
```

## AI Effort Compression Table

| Task Type | AI Compression | Notes |
|---|---|---|
| Boilerplate | ~100x | Generate instantly |
| CRUD endpoints | ~50x | Template-based |
| Test writing | ~20x | Good at happy path |
| Refactoring | ~10x | Needs human judgment |
| Architecture | ~3-5x | Most human input needed |
| Debugging | ~2-5x | Depends on context |

## Sprint Workflow: Think -> Plan -> Build -> Review -> Test -> Ship -> Reflect

Each skill feeds output into the next. Never skip "Reflect" — that's where the compound learning happens.
