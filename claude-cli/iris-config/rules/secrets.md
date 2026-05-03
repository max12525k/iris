# Secrets & credentials

Read when handling API keys, tokens, `.env*`, OAuth credentials, or any value that must not appear in logs, commits, chat history, or subagent prompts.

## Hard "never"

- **Never echo, print, log, or `cat` a secret value.** Reference by env var name (`$OPENAI_API_KEY`), not by value.
- **Never paste a secret into an LLM message.** Vendor logs and downstream pipelines persist input. Once a secret enters a model context, treat it as compromised.
- **Never pass secrets to subagents in prompts.** Subagents have separate context — leaking through fan-out is silent.
- **Never include secrets in commit messages, PR bodies, or memory files.** Even if later edited, git history and memory snapshots retain them.

## File hierarchy

| File | Holds | Committed? |
|---|---|---|
| `.env`, `.env.local`, `.env.production` | live values | ❌ never |
| `env.example`, `.env.example` | keys with placeholder values | ✅ yes — documents required vars |
| `~/.zshenv` / shell rc | cross-project user secrets (`GH_TOKEN`, `AWS_*`) | ❌ |
| Compose `secrets:` block / Docker secrets | production secrets in containers | ❌ |

If a `.env*` is already tracked in git, **surface it to the user**. Don't silently `git rm`. The fix is rotation + remove-from-history, in that order.

## Rotation triggers — assume compromised if the secret has been:

1. **Pushed to a remote**, even briefly. GitHub caches SHAs ~90 days — `git push --force` doesn't undo this.
2. **Pasted into chat / Slack / Discord / a screen recording.**
3. **Logged to a file, stdout, or a debugger frame.**
4. **Sent to a third-party service** (LLM providers, error trackers, analytics).

Rotation flow:
1. Generate new value, update all consumers.
2. Revoke the old value at the issuer.
3. Document the rotation (date + reason) in the project's runbook.

## Multi-provider gateway (LiteLLM)

- Each provider key (`OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `GEMINI_API_KEY`, …) has its own scope. Rotate independently.
- `LITELLM_MASTER_KEY` is the gateway's meta-credential — compromise lets an attacker mint downstream proxy keys. Treat as highest-tier; rotate aggressively on any exposure signal.
- Prefer minting one **virtual key** per consumer app over sharing the master key.

## Discovery in a new project

When entering an unfamiliar repo, check for:
- `.env*` tracked in git: `git ls-files | grep -E '^\.env'`
- Hard-coded secrets in source: `rg -i "api[_-]?key|secret|token|password" -g '!*.lock'`
- `.gitignore` and `.dockerignore` cover `.env*`

Surface findings to the user before continuing. Don't auto-remediate.

---
**Sources:** [OWASP Cheat Sheet — Secrets Management](https://cheatsheetseries.owasp.org/cheatsheets/Secrets_Management_Cheat_Sheet.html), [GitHub — about secret scanning](https://docs.github.com/en/code-security/secret-scanning/about-secret-scanning), [LiteLLM — virtual keys](https://docs.litellm.ai/docs/proxy/virtual_keys).
