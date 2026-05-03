# CLAUDE.md

Behavioral guidelines to reduce common LLM coding mistakes. Merge with project-specific instructions as needed.

**Tradeoff:** These guidelines bias toward caution over speed. For trivial tasks, use judgment.

## 1. Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

Before implementing:
- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them - don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.

## 2. Simplicity First

**Minimum code that solves the problem. Nothing speculative.**

- If you write 200 lines and it could be 50, rewrite it.
- Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

## 3. Surgical Changes

**Touch only what you must. Clean up only your own mess.**

When editing existing code:
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it - don't delete it.

When your changes create orphans:
- Remove imports/variables/functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.

The test: Every changed line should trace directly to the user's request.

## 4. Goal-Driven Execution

**Define success criteria. Loop until verified.**

Transform tasks into verifiable goals:
- "Add validation" → "Write tests for invalid inputs, then make them pass"
- "Fix the bug" → "Write a test that reproduces it, then make it pass"
- "Refactor X" → "Ensure tests pass before and after"

For multi-step tasks, state a brief plan:
```
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]
```

Strong success criteria let you loop independently. Weak criteria ("make it work") require constant clarification.

## 5. Topical rules (read on demand)

When a task touches one of these domains, Read the matching file before acting. Don't preload — fetch only when relevant.

- Python (uv, venvs, package install) → `~/.claude/rules/python.md`
- Subagent spawns (Agent tool, context bundles) → `~/.claude/rules/subagents.md`
- Git / GitHub (commits, branches, PRs, `gh`) → `~/.claude/rules/github.md`
- Docker (compose, Dockerfile, images, containers) → `~/.claude/rules/docker.md`
- Secrets (`.env*`, API keys, tokens, credentials) → `~/.claude/rules/secrets.md`
- LLM evals (prompts, agents, course examples, model swaps) → `~/.claude/rules/llm-evals.md`
- Skills (install, audit, third-party marketplaces, defense layers) → `~/.claude/rules/skills.md`

For how rules themselves are authored, updated, and loaded, see `~/.claude/rules/README.md`.

---

**These guidelines are working if:** fewer unnecessary changes in diffs, fewer rewrites due to overcomplication, and clarifying questions come before implementation rather than after mistakes.
