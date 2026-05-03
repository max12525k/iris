# LLM evals

Read when designing prompts, agents, course examples, or any "model does X reliably" claim. Evals catch the regressions linting, type checks, and unit tests can't — LLM outputs are non-deterministic, and silent drift is the default failure mode.

## When an eval is **required**

- Prompts that ship to production users.
- Model swaps (Opus → Sonnet, version → version) — behaviour shifts even when "the prompt didn't change".
- Course / tutorial examples that demonstrate a specific behaviour. Without a re-runnable eval the course rots.
- Any agent or tool whose value rests on a reliability claim ("classifies tickets correctly 95%+ of the time").

## When eval is **overkill**

- One-shot exploration scripts.
- Internal debug prompts you'll discard.
- Rapid prototypes where the cost of being wrong is "the user re-prompts".

If you can't picture the regression you'd catch, you don't need the eval yet.

## Eval shape

| Field | Default |
|---|---|
| Cardinality | 10–30 cases for behaviour; 100+ only when safety-critical |
| Pass threshold | 95%+ for behaviour; 100% for safety / refusal |
| Criterion | exact match → regex → semantic → LLM-as-judge — pick the cheapest that catches the regression |
| Golden set | (input, expected criterion) pairs, version-controlled, never edited to "fix" a failing run |

A failing eval is a signal — investigate the prompt or model. Don't update the golden set to make it pass.

## Tooling

| Tool | Use when |
|---|---|
| [Promptfoo](https://www.promptfoo.dev/) | CI integration, declarative YAML, multi-model side-by-side |
| Anthropic console evals | Quick manual loops on `claude.ai` |
| `eval-harness` skill | Formal eval-driven-development inside this harness |
| Custom Python | Bespoke metric not covered by a framework |

Default to Promptfoo for shipped prompts. Reach for custom only when the metric is unusual.

## For courses (deep-tech business)

- **Pin model IDs:** `claude-opus-4-7`, not `claude-opus`. Aliases shift.
- **Last-tested date** in the course README. Re-run on every major model release.
- **One eval per learning objective.** If a sample teaches "the agent reasons about retries", an eval enforces it.

## For multi-provider gateways (LiteLLM-style)

- Eval the **routing policy**, not just one provider. The eval should pass with any backend that meets the spec.
- Track **per-provider drift** over time. Small accuracy shifts are normal; sudden cliffs mean the provider changed something upstream.

---
**Sources:** [Anthropic — Verify your work](https://code.claude.com/docs/en/best-practices#give-claude-a-way-to-verify-its-work), [Anthropic — Building effective agents](https://www.anthropic.com/research/building-effective-agents), [Promptfoo](https://github.com/promptfoo/promptfoo).
