# Git & GitHub rules

Read when working with `git`, `gh`, branches, commits, PRs, or merges. Hard safety rules (force push, `--no-verify`, hook-failure handling, `--amend` of published commits) are in Claude Code's built-in system prompt — this file adds the user's conventions on top.

## Files never committed

- `.env`, `.env.*` — live secrets. Templates (`env.example`, `.env.example`) are fine.
- `.claude/` — local Claude Code state, not project source.

If any of these appear as untracked when staging, surface them and stage the rest **by explicit filename**. Never `git add .` / `git add -A` / `git add *` — bulk add can sweep secrets, build output, or `.claude/` state. For rotation flow when `.env*` was already committed, see `~/.claude/rules/secrets.md`.

## Conventional Commits

**Before the first commit in a new repo**, run `git log -5 --oneline` to sample existing style. If the repo doesn't use Conventional Commits, mirror its convention instead of forcing CC — consistency beats orthodoxy.

Default format: `type(scope): subject`. Subject ≤ 72 chars, imperative mood, focus on *why* not *what*.

| Type | Use for |
|---|---|
| `feat` | new user-visible capability |
| `fix` | bug fix |
| `refactor` | code change with no behavioural diff |
| `perf` | performance improvement |
| `test` | tests only |
| `docs` | docs only |
| `build`, `ci`, `chore` | tooling, CI, housekeeping |

Compose multi-line messages with `git commit -m "$(cat <<'EOF' … EOF)"` so formatting and trailers survive.

## Atomic commits

One logical change per commit. If the working tree mixes concerns, split into separate commits — don't bundle. No "WIP" / "fix typo" noise on a branch that will be PR'd.

## Branches

`<type>/<short-slug>` — e.g. `feat/oauth-callback`, `fix/null-token`, `chore/bump-litellm`. Mirror the repo's existing style if it differs.

Never commit directly to `main` / `master` / `release/*`. Branch + PR.

## Pull requests

- **Verify `gh auth status` before relying on `gh`.** If not authenticated, ask the user — don't loop on auth failures.
- **If the repo has a `CONTRIBUTING.md` or `.github/PULL_REQUEST_TEMPLATE.md`**, follow that structure instead of the default below.
- Use `gh pr create` (the `gh` CLI is allowlisted in `settings.local.json`).
- Title ≤ 70 chars; details belong in the body.
- Default body sections:
  - `## Summary` — 1–3 bullets, the *why*
  - `## Test plan` — checklist of how the change was verified
- Pre-PR: run tests / lint / typecheck if the repo has them. If you can't, say so explicitly in the test plan.

## Investigate before destructive ops

Unknown branches, untracked files, unfamiliar lockfiles → **ask, don't delete**. They may be the user's in-progress work. Same applies to stash entries and detached HEADs.

---
**Sources:** [Anthropic — Claude Code best practices](https://code.claude.com/docs/en/best-practices), [Conventional Commits 1.0](https://www.conventionalcommits.org/), community patterns in [`awesome-claude-code-toolkit`](https://github.com/rohitg00/awesome-claude-code-toolkit) and [`affaan-m/everything-claude-code/rules/common/git-workflow.md`](https://github.com/affaan-m/everything-claude-code/blob/main/rules/common/git-workflow.md).
