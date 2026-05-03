# Subagent rules

**Every `Agent({...})` call must pass a context bundle, not a fresh start.** Subagents inherit no L1 memory and no skill listing. Without a bundle, the subagent re-discovers everything from scratch — that's where token cost compounds.

## Custom agents available in this harness

Pick the narrowest `subagent_type` that fits before defaulting to `general-purpose`:

| `subagent_type` | Use for |
|---|---|
| `code-architect` | feature blueprints, files-to-touch, build order |
| `harness-optimizer` | tuning this harness's settings, hooks, rules |
| `loop-operator` | running / monitoring `/loop` cycles |
| `python-reviewer` | PEP 8 / Pythonic / type / security review of Python changes |
| `silent-failure-hunter` | swallowed errors, bad fallbacks, missing propagation |
| `Explore` (built-in) | broad codebase search across many files |
| `Plan` (built-in) | designing implementation plans |

## The bundle (required fields)

Every Agent prompt must include:

1. **What & why** — the goal in one sentence + *why* it matters, so the agent can judge edge cases.
2. **Memory slice** — 3–5 facts pre-fetched from MEMORY.md or `mempalace_search`, inlined. Subagents have no MEMORY.md; without this they guess what you already knew.
3. **Skill hints** — names of skills (e.g. `simplify`, `review`). Subagents have no skill catalog; without names they can't reach for the right one.
4. **Output format** — exact shape and length cap (e.g. *"punch list, under 200 words"*). Without a cap, raw output dumps into your context.
5. **Tool boundaries** — narrower than the `subagent_type` default if needed (e.g. "read-only"). Without this, the agent wanders.

## Example — bundled prompt

```
Agent({
  description: "Review PR",
  subagent_type: "general-purpose",
  prompt: `Review PR #42 (branch feat/auth-rewrite).

  Context: rewrites auth middleware. Goal is compliance fix (legal flagged
  session-token storage). Scope is auth/ only — don't comment elsewhere.

  Relevant memory:
  - Project uses jose for JWTs (not jsonwebtoken).
  - Session tokens must not log to stdout (PII rule).

  Skills available: review, security-review.

  Report: 3 most-load-bearing risks (1 line each); whether the compliance
  ask is satisfied (yes/no/partial); under 200 words total.`
})
```

A non-bundled equivalent (`"Review the PR and tell me what you think"`) wastes the spawn — the agent re-discovers what you already knew.

## Writer / Reviewer pattern

For any non-trivial change, spawn a *separate* subagent to review what you (or another agent) just wrote. The reviewer's fresh context isn't biased toward the code it produced and catches edge cases the writer missed. Use for security-sensitive changes, migrations, and anything warranting a second pair of eyes.

## When the bundle is overkill

Skip for **research-only** spawns where the answer is independent of project state (e.g. *"summarize this Wikipedia article"*).

## Parallel spawns & fan-out

Each agent in a parallel call gets its own bundle — they don't see each other. For same-operation-across-many-files work (migrations, batch refactors), prefer `claude -p "<prompt>" --allowedTools …` in a shell loop over many `Agent` spawns: cheaper, scriptable, blast radius constrained by `--allowedTools`.

## Reconciliation

The return value is the agent's *best summary*, not ground truth. Spot-check the most consequential claim before acting. Most subagent output is ephemeral.

---
**Sources:** [Anthropic — Manage context aggressively](https://code.claude.com/docs/en/best-practices#manage-context-aggressively), [Anthropic — Use subagents for investigation](https://code.claude.com/docs/en/best-practices#use-subagents-for-investigation), [Anthropic — Run multiple sessions](https://code.claude.com/docs/en/best-practices#run-multiple-claude-sessions).
