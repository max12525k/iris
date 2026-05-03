# Skill safety rules

Read when installing, updating, auditing, or troubleshooting Claude Code skills (`~/.claude/skills/`, `~/.claude/plugins/`, third-party marketplaces). A skill is just a prompt — it can instruct the model to call any tool the harness allows. The defenses below assume an adversarial skill author.

## Hard "never" before installing a skill

- **Never enable a skill without reading its `SKILL.md` first.** Look for `curl|sh`, `eval`, `base64 -d`, `.env`, `~/.ssh`, prompt-injection phrases ("ignore previous instructions").
- **Never enable a skill from an unpinned source.** Pin marketplaces by commit SHA in `extraKnownMarketplaces`, not branch.
- **Never `audit-skills.sh` a third-party repo and enable its skills in the same session.** Audit first; enable only after review in a separate session.

## Defense layers in this harness

| Layer | What it does | File |
|---|---|---|
| `permissions.deny` | Hard-blocks reads of `~/.ssh`, `~/.aws`, `~/.gnupg`, Claude transcripts | `~/.claude/settings.json` |
| `PreToolUse` hook | Scans Bash/Read/Write/Edit calls for exec-from-network, credential paths, `.env` reads, self-modifying skills | `~/.claude/hooks/skill-defense/pretool-guard.sh` |
| Auditor | Greps all skill files for red flags + diffs against snapshot | `~/.claude/hooks/skill-defense/audit-skills.sh` |
| Snapshot baseline | SHA256 of every skill file; auditor flags drift | `~/.claude/hooks/skill-defense/snapshot.sha256` |

## Bypass — when something legitimate gets blocked

In order of preference:

1. **`! <command>` in the Claude prompt.** Runs in your shell, never goes through Claude tools — the cleanest bypass for one-off network installers.
2. **Project-local allow rule** in `<project>/.claude/settings.local.json` — scoped to one project, doesn't weaken global posture. Best for legitimate project-specific needs (e.g. that project's own `.env`).
3. **Add a regex to** `~/.claude/hooks/skill-defense/trusted-patterns.txt` — global pattern allowlist. Use sparingly; every entry weakens defense.
4. **`CLAUDE_SKILL_DEFENSE=off claude`** — disables the hook for one session. Bypass is logged to `guard.log`. Don't make it a habit.

## When the auditor flags drift

Re-run `audit-skills.sh`. Inspect the changed files. If you trust the change (you updated a skill yourself, or a known-good marketplace pushed an update you reviewed), re-baseline:

```
~/.claude/hooks/skill-defense/snapshot.sh
```

If the change is unexplained, **disable the skill before resolving** — move it out of `~/.claude/skills/` or set `skillOverrides.<name>: "name-only"` until you've reviewed.

## Why these layers stack

A determined adversarial skill can prompt-inject the model to wrap its payload in a benign-looking helper. `permissions.deny` is enforced by the harness, not the model — it can't be talked around. The `PreToolUse` hook adds depth (regex over command bodies that the allowlist DSL can't express). The auditor + snapshot is post-hoc detection — it won't stop the first malicious run, but it catches persistence and drift.

## Logs and operations

- Hook decisions log to `~/.claude/hooks/skill-defense/guard.log` — review periodically. `BYPASS:` entries mean someone disabled the guard.
- Auditor and snapshot are read-only; safe to run any time.
- `false positives` are expected (e.g. a math/grader skill containing "you are now a..."). The auditor surfaces, never auto-acts.
