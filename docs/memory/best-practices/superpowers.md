# Best Practices from obra/superpowers

> Source: https://github.com/obra/superpowers (155k stars)
> An agentic skills framework that transforms AI coding assistants into disciplined engineering partners.

## The 7-Stage Workflow (NEVER skip stages)

1. **Brainstorm** — extract the real requirement
2. **Plan** — write detailed enough for "an enthusiastic junior engineer with poor taste and no judgement"
3. **Execute** — follow the plan, don't freestyle
4. **TDD** — test-driven, always
5. **Review** — request code review before declaring done
6. **Verify** — prove it works (not just "it compiles")
7. **Finish** — clean up, commit, PR

## Key Patterns to Copy into CLAUDE.md

```markdown
# In your project CLAUDE.md, add:

## Workflow Rules
- Never jump to code without a plan. Use /plan first.
- Write plans detailed enough for someone with zero context.
- Never accept "done" without evidence (tests pass, screenshot, curl output).
- Each task gets its own git worktree to prevent cross-contamination.
- Break large tasks into parallel subtasks dispatched to subagents.
```

## High Bar for Quality

Superpowers sets a **94% PR rejection rate** framing in CLAUDE.md — forces the agent to take quality seriously. Replicable pattern:

```markdown
# Add to CLAUDE.md:
Most AI-generated PRs are rejected. To avoid rejection:
- Every change must have a test
- Every function must have a clear purpose
- No "helpful" additions beyond what was asked
```

## Git Worktrees as First-Class Workflow

Each task = its own worktree. No cross-contamination. Copy pattern:
```bash
# Start new task
git worktree add .worktrees/feat-xyz -b feat/xyz
cd .worktrees/feat-xyz
# ... work ...
# When done, remove worktree
cd - && git worktree remove .worktrees/feat-xyz
```
