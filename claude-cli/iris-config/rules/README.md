# How rules work in `~/.claude/rules/`

Rules are **on-demand domain reading**, not auto-loaded. They fire only when a task touches the domain *and* `~/.claude/CLAUDE.md` points to them. This file documents how to write, update, and load rules.

## Where does this guidance belong?

| Type of guidance | Home | Loads when |
|---|---|---|
| Behavioural baseline for every session | `~/.claude/CLAUDE.md` (≤ 60 lines) | Always |
| Domain-scoped (Python, Git, Docker…) | `~/.claude/rules/<topic>.md` | Read on demand |
| Must happen deterministically | A hook in `~/.claude/settings.json` | Tool / lifecycle event |
| User identity, project state | Auto-memory (`memory/`, `MEMORY.md`) | Project sessions |
| Reusable workflow with arguments | A skill (`~/.claude/skills/<name>/SKILL.md`) | Domain match |
| Cross-session knowledge graph | MemPalace (drawers, tunnels) | Explicit query |

If two homes fit, prefer the one that loads **least**. The cost of a rule is context, not bytes.

## When a new rule is justified

A new file in `~/.claude/rules/` is warranted only if all four hold:

1. **Domain-scoped** — a clear trigger phrase or task type ("commit", "PR", "uv", "docker compose").
2. **Recurring** — the same drift has been seen twice, or is expected to.
3. **Not in built-ins** — Claude Code's system prompt and CLAUDE.md don't already cover it.
4. **Stable** — won't change in a week.

Otherwise: leave it as a memory note (`memory/feedback_*.md`) and revisit later. Premature rules bloat context.

## Anatomy of a rule file

```
# <Domain> rules

Read when <trigger phrases>. <One-line scope: what this adds vs duplicates built-ins>.

## <Section — lead with the hardest "never">
- imperative bullets
| table | for "use this, not that" mappings |

## Why <load-bearing rule>?
One sentence — lets future-you judge edge cases instead of blindly following.

---
**Sources:** auditable links (community pattern, RFC, Anthropic doc).
```

Style:
- **Imperative.** "Use uv." Not "It's recommended to use uv when possible."
- **Terse.** Cut anything that just restates language defaults Claude already knows.
- **Tables for mappings, bullets for hard rules, prose only for *why*.**
- **Cite sources** at the bottom — keeps the file auditable when the practice shifts.
- **Target ≤ 80 lines.** If it won't fit, it's two rules — split by trigger.

## Updating an existing rule

Triggers to update:
- A correction from the user lands inside the rule's domain.
- The community standard the rule cites has shifted.
- An edge case keeps coming up that the rule's "Why" doesn't cover.

How:
1. **Edit in place.** Don't append changelogs inside the file — git history is the changelog. The file should read like the current state, not an archaeological dig.
2. **Add a line, prune a line.** Net length stays flat. If you can't prune, the rule is growing past its scope — consider splitting.
3. **Refresh sources** if a citation moved.
4. **If the rule has been wrong twice in different ways, rewrite — don't patch.**

## How a rule gets loaded into a session

Rules don't auto-load. The trigger is the "Topical rules" section of `~/.claude/CLAUDE.md`:

```
- Python (uv, venvs, install) → `~/.claude/rules/python.md`
- Git/GitHub (commits, branches, PRs) → `~/.claude/rules/github.md`
```

To make a new rule discoverable:

1. Add a one-line entry to that section. **Trigger keywords on the left, file path on the right.**
2. Match how the user actually phrases tasks ("commit", "PR", "branch" — not just "github").
3. Do **not** inline the rule's content into CLAUDE.md. The pointer is the contract.

If a rule isn't being read when it should be, the trigger keywords are wrong — fix CLAUDE.md, not the rule.

## Pruning

Periodically (quarterly, or when CLAUDE.md feels noisy):
- Read each rule. Delete sections that haven't fired in months.
- Merge files with overlapping triggers (e.g. `docker.md` + `compose.md` → one file).
- If a rule is silently shadowed by a built-in, delete the rule.

A 100-line rule that's never read is worse than no file: it pretends to be authoritative.
