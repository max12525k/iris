# Virtual keys & model routing

LiteLLM sits in front of OpenRouter (cloud) + local Ollama. Iris talks only to LiteLLM
using a **virtual key** — never the real OpenRouter key. Each virtual key has its own
budget, rate limit, and audit trail.

## Active virtual keys

| Alias | Where the key lives | Budget | Rate limit | Allowed models |
|---|---|---|---|---|
| `iris-default` | `.env` → `IRIS_VIRTUAL_KEY` | $50 / 30 days | 60 RPM, 100K TPM | All seven `iris-*` aliases |

Mint additional keys (e.g. for a separate workflow with its own budget) via:

```bash
MASTER=$(grep LITELLM_MASTER_KEY litellm/.env | cut -d= -f2)
curl -X POST http://127.0.0.1:4000/key/generate \
  -H "Authorization: Bearer $MASTER" \
  -H "Content-Type: application/json" \
  -d '{"key_alias":"<name>","models":["iris-default", "..."],"max_budget":...,"budget_duration":"30d"}'
```

Or use the LiteLLM admin UI: <http://127.0.0.1:4000/ui> (master key from `litellm/.env`).

## Virtual aliases — what to use when

| Alias | Maps to | Best for | Per-1M cost (in / out) |
|---|---|---|---|
| `iris-default` | Kimi K2.6 (OpenRouter) | Primary orchestrator, general workhorse, agentic loops | $0.74 / $3.49 |
| `iris-cheap` | Qwen3.6 Plus (OpenRouter) | High-volume verifiable tasks (tool-validated, code-tested, structured extraction). 26.5% fabrication on API knowledge — don't use for unverified work | $0.33 / $1.95 |
| `iris-research` | Claude Opus 4.7 (OpenRouter) | Escalation route for ambiguous planning, deep reasoning, top-tier creative writing | $5 / $25 |
| `iris-coding` | GLM-5.1 (OpenRouter) | Daily code workflow with tool calls — first open-weight to top SWE-bench Pro | $1.05 / $3.50 |
| `iris-marketing` | Kimi K2.6 (OpenRouter) | Creative writing, copy. Same backend as default but separate alias for budget tracking | $0.74 / $3.49 |
| `iris-briefing` | Gemini 3 Flash (OpenRouter) | Daily summaries (long input → short output). Stable cheap throughput | $0.50 / $3 |
| `iris-private` | qwen2.5:32b (local Ollama) | Sensitive prompts that must never leave the machine. Skipped Presidio guardrails since the prompt stays local | local — free |

## Real-backend aliases (direct routing)

For ad-hoc calls outside the workflow categories above, every backend is also exposed
under its plain name in `litellm/config.yaml`: `claude-opus`, `claude-sonnet`,
`claude-haiku`, `gpt-5`, `gpt-5-mini`, `gemini-pro`, `gemini-flash`, `kimi`, `qwen-plus`,
`glm`, `ollama-local`.

These bypass the `iris-*` alias semantics — use them only for one-off requests where
you specifically want a particular model (e.g. comparing two models on the same prompt).
The `iris-*` aliases route through LiteLLM's fallback chains; the plain names do not.

## Fallback chain

```
iris-default (Kimi)         ─[error]─→  iris-research (Opus)
iris-research (Opus)         ─[error]─→  iris-default (Kimi)
iris-coding (GLM)            ─[error]─→  iris-default → iris-research
iris-marketing (Kimi)        ─[error]─→  iris-research (Opus)
iris-cheap (Qwen)            ─[error]─→  iris-default (Kimi)
iris-briefing (Gemini Flash) ─[error]─→  iris-default (Kimi)
```

Policy: "Opus only when Kimi doesn't work" — default → Opus is a single hop, all other
aliases fall back to Kimi (cost-aware), then Kimi escalates to Opus.

## Guardrails (active on all six cloud aliases; iris-private skipped)

- **`presidio-pii`** (pre-call):
  - **BLOCK** `CREDIT_CARD`, `US_SSN`, `IBAN_CODE` — request rejected entirely
  - **MASK** `EMAIL_ADDRESS`, `PHONE_NUMBER` — replaced with `<EMAIL_ADDRESS>` / `<PHONE_NUMBER>` placeholders before reaching the upstream model
- **`hide-secrets`** (pre-call): `detect-secrets`-based scanner catches AWS keys, GitHub tokens, etc.

## Audit log

Every call is logged to the `LiteLLM_SpendLogs` table in `litellm-db`:

```bash
docker compose exec -T litellm-db psql -U llmproxy -d litellm -c \
  "SELECT call_type, model_group, model, total_tokens, spend, custom_llm_provider, \"startTime\" \
   FROM \"LiteLLM_SpendLogs\" ORDER BY \"startTime\" DESC LIMIT 20;"
```

Columns of interest:
- `model_group` — the alias Iris asked for (`iris-default`)
- `model` — the actual backend dispatched (`openrouter/moonshotai/kimi-k2.6`)
- `spend` — USD cost of the call
- `custom_llm_provider` — proves which provider handled it
