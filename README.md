# Iris — Personal AI Assistant Stack

A self-hosted, privacy-routed AI assistant built on [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent). Brain runs on Kimi K2.6 via [LiteLLM](https://github.com/BerriAI/litellm) over OpenRouter; can delegate coding tasks to Claude Code (your Claude Max plan) via a sidecar; falls back to local Ollama for sensitive prompts. Persistent memory via [Honcho](https://github.com/plastic-labs/honcho). Every cloud call passes through [Presidio](https://github.com/microsoft/presidio) PII guardrails.

**V2 (current `main`)** adds five planes on top: observability (OTel + Loki + Grafana), self-learning loop (lessons memory + Hermes Curator + periodic nudges), event log + Iris Curator (GitOps split — fast autonomous observation, slow reviewed intent), multi-profile fleet (persona / researcher / coder / ops, opt-in), and an append-only audit log Postgres for compliance. See [V2_INSTALL.md](V2_INSTALL.md) for the full architecture spec, [PHASE_5_SANDBOX.md](PHASE_5_SANDBOX.md) for the sandbox-runtime decision tree, and [PHASE_7_TENANCY.md](PHASE_7_TENANCY.md) for the corporate / multi-tenant deltas.

## What you get

| Service | Purpose | Reach via |
|---|---|---|
| `iris-dashboard` | Hermes web UI (chat tab, sessions, skills) | http://127.0.0.1:9119 |
| `litellm` | LLM proxy + virtual keys + audit + Presidio guardrails | http://127.0.0.1:4000 |
| `grafana` | **Mission Control** — fleet overview, agent detail, compliance dashboards (V2) | http://127.0.0.1:3000 |
| `prometheus` | Metrics scrape (LiteLLM + OTel collector + Hermes /metrics) | http://127.0.0.1:9090 |
| `iris-gateway` | Hermes runtime (messaging adapters, cron, brain) | internal |
| `claude-cli` | Claude Code sidecar — uses your Claude Max plan via OAuth | internal, called via wrapper |
| `honcho-api` + `honcho-deriver` | Semantic memory + dialectic user model (pgvector + redis) | internal |
| `presidio-analyzer` + `presidio-anonymizer` | PII detection & masking before any cloud call | internal |
| `otel-collector` + `loki` + `promtail` | V2 telemetry plane: traces, logs, span aggregation | internal |
| `audit-db` | V2 append-only Postgres for SOC2/HIPAA-grade audit trail | internal |
| `litellm-db`, `honcho-db`, `honcho-redis` | Persistence | internal |

**17 containers default + 3 opt-in profile gateways** (`iris-researcher`, `iris-coder`, `iris-ops` — bring up via `docker compose --profile fleet up -d`). Three Docker bridge networks: `frontend` (host loopback), `backend` (internal), `data` (internal). Internal services are not exposed to the host or LAN.

## Prerequisites

- macOS or Linux (tested on macOS 15)
- **Docker Desktop ≥ 4.30** (Compose ≥ v2.20 — we use the `include:` directive)
- ~25 GB free disk for images + Ollama models
- An **OpenRouter API key** (https://openrouter.ai/keys) — only one cloud key needed; everything routes through OpenRouter
- A **Claude Max plan** (optional, only if you want the Claude Code sidecar) + Claude Code CLI authenticated locally
- Ollama (auto-installed via Homebrew if missing)

## Quickstart (8 commands)

```bash
# 1. Clone
git clone <YOUR_FORK_URL> iris && cd iris

# 2. Generate stack secrets (DB passwords + LiteLLM master/salt keys)
bash scripts/setup-secrets.sh

# 3. Add your OpenRouter API key to litellm/.env (replace the placeholder)
# Edit litellm/.env in your editor, OR use sed:
sed -i.bak "s|OPENROUTER_API_KEY=sk-or-\.\.\.|OPENROUTER_API_KEY=YOUR_KEY|" litellm/.env && rm litellm/.env.bak

# 4. Clone upstream Hermes + Honcho repos as Docker build contexts
git clone --depth 1 https://github.com/NousResearch/hermes-agent.git
git clone --depth 1 https://github.com/plastic-labs/honcho.git honcho-src

# 5. (Optional, ~19 GB) Install Ollama + pull privacy-route model
# Universal install (macOS + Linux):
curl -fsSL https://ollama.com/install.sh | sh
# Then start it (macOS: `brew services start ollama` if installed via brew;
#                Linux: `sudo systemctl start ollama`)
ollama pull qwen2.5:32b

# 6. Create the workspace dir Iris uses for file work
mkdir -p ~/iris-workspace

# 7. Build images + start the stack (slow first time: ~20 min for Hermes/Playwright)
make dev

# 8. (Optional) One-time Claude Code OAuth login for the sidecar — uses your Max plan
docker compose exec -T --user root claude-cli chown -R claude /home/claude/.claude
docker exec -it claude-cli claude  # paste OAuth URL into browser, paste code back
```

After step 7, dashboard is at http://127.0.0.1:9119. After step 8, `claude-cli` can run tasks against your Max plan billing.

To mint a virtual key for Iris and apply the optimized config (one-time, idempotent):

```bash
bash scripts/mint-iris-key.sh    # mints virtual key → .env, renders iris/iris-config/config.template.yaml,
                                  # writes config.yaml + SOUL.md into iris-gateway, restarts
```

The applied config has community-tuned optimizations:
- **1h prompt cache TTL** (saves $400-850/mo for active users per upstream issue #14971)
- **`skills.loading: lazy`** — one-line skills catalog instead of all 89 skills inlined; saves ~2K tokens off every system prompt (upstream issue #2045)
- **`reasoning_effort: low`** — Kimi K2.6 defaults to medium reasoning (1000+ tokens/turn); low cuts that ~50%. Escalate at runtime with `/reasoning high`
- **`max_tokens: 4096`** — output cap to prevent runaway responses (Kimi default ceiling is 262K)
- **50%-threshold compression** with `target_ratio: 0.10` — tighter post-compression context multiplies savings across the rest of the session
- **Per-task auxiliary routing** — compression + vision → Gemini 3 Flash; title_gen + session_search + web_extract + skills_hub + mcp → Qwen3.6 Plus; approval (security-relevant) stays on main. Saves 50-70% on aux spend vs all-on-main
- **Layer-1 Presidio hook** auto-accepted for the non-interactive gateway

To customize Iris's persona, edit `iris/iris-config/SOUL.md` and re-run `mint-iris-key.sh`. To change config defaults, edit `iris/iris-config/config.template.yaml`.

**Optional next step — messaging bots:** to talk to Iris from Telegram or Discord (instead of just the web dashboard), see [INSTALL.md Phase G.13](INSTALL.md). Add tokens to `.env`, recreate iris-gateway, you have a personal assistant in your messaging client of choice.

## V2 capabilities at a glance

Iris's wrappers (V1 + V2) — what she can do without manual help:

| Wrapper | Effect | Manifest |
|---|---|---|
| `iris-learn <eco> <pkg>` | Install package now + commit to manifest for fresh-clone reproducibility | `iris/iris-learned/{apt,python,npm}.txt` |
| `iris-cron add\|rm\|list` | Schedule a recurring job; survives recreate + fresh-clone | `iris/iris-config/cron.yaml` |
| `iris-skill install\|uninstall\|list` | Install a Hermes skill from registries; snapshot persisted | `iris/iris-config/skills.json` |
| `iris-mcp add\|rm\|list` | Connect/disconnect an MCP server; replayed at boot | `iris/iris-config/mcp.yaml` |
| `iris-curator [--since 24h] [--tenant X]` | Distill the event log into a markdown summary for review | `iris-curator-pending/distill-*.md` |
| `_record_lesson` | Auto-called on wrapper failures; lessons surface as a Hermes user-message skill next session | `/opt/data/iris-lessons.jsonl` |
| `_event_log` / `_audit_emit` | Every wrapper action lands in `iris-events.db` (operational SQLite) and `audit_log` Postgres (compliance) | both |

Hermes-native features wired up in V2:
- **Curator** runs nightly via `iris.nightly-curator` cron — archives stale skills, consolidates duplicates
- **Periodic skill-creation nudge** every 15 tool calls (Hermes prompts Iris to consider saving a skill)
- **Memory-save nudge** every 10 user turns (Hermes prompts Iris to persist to Honcho)
- **Honcho dialectic** — wrapper failures land here as conclusions when an embedding key is configured

## Mission Control (Grafana dashboards)

http://127.0.0.1:3000 — three pre-provisioned dashboards in the "Iris V2" folder:

- **Fleet Overview** (`iris-v2-fleet-overview`) — wrapper rate, failure rate, recent events, LiteLLM throughput
- **Compliance & Audit** (`iris-v2-compliance-access`) — backed by audit-db; SOC2/HIPAA-shaped queries
- **Agent Detail** (`iris-v2-agent-detail`) — drill into one profile via the `$profile` selector

Anonymous Viewer is enabled for read-only access; `admin` / `admin` for editing. Datasources auto-provisioned: Prometheus, Loki, AuditDB.

## How to actually talk to Iris

Three surfaces, all sharing the same brain + memory + guardrails:

1. **Web dashboard Chat tab** at http://127.0.0.1:9119 — the dashboard ships with a `Chat` tab that embeds the full Hermes TUI in your browser (slash commands, model picker, streaming, the works). Refresh the page; the tab appears in the nav.
2. **Telegram / Discord bots** — once configured per [INSTALL.md G.13](INSTALL.md), DM your Telegram bot or @-mention your Discord bot. Same Iris everywhere.
3. **CLI inside the container** — `docker compose exec -it iris-gateway hermes` for an interactive REPL. Useful for debugging.

For one-shot queries:
```bash
docker compose exec -T iris-gateway /opt/hermes/.venv/bin/hermes -z "your question"
```
(`-z` is the prompt flag — `-p` is "profile". The full venv path is needed because the bare `hermes` isn't on the default exec PATH.)

Useful slash commands once you're chatting:
- `/model` — switch which `iris-*` route to use for this turn
- `/reasoning low|medium|high|xhigh` — dial reasoning effort (Kimi K2.6 burns reasoning tokens by default)
- `/compress` — manually summarize the conversation now
- `/usage` — tokens + cost for this session
- `/cc <task>` — route the whole turn to Claude Code via the sidecar (uses your Max plan)
- `/clear` — start a fresh session, drop context

## Day-to-day ops

```bash
make dev          # start (build if needed) — 17 containers
make down         # stop (volumes preserved)
make logs SERVICE=iris-gateway   # tail one service
make ps           # status of all containers
make backup       # one-shot manual backup (schedule via cron / systemd timer / launchd — see INSTALL.md G.3)
make rebuild      # rebuild Iris + Honcho images after upstream pulls
make pull         # update remote images (litellm, postgres, prometheus, etc.)

# V2 multi-profile fleet (opt-in):
docker compose --profile researcher up -d   # bring up researcher gateway
docker compose --profile coder      up -d   # bring up coder gateway
docker compose --profile ops        up -d   # bring up ops gateway
docker compose --profile fleet      up -d   # bring up all three
```

Backups go to `./backups/<date>/` — three artifacts (litellm.sql.gz, honcho.sql.gz, iris_data.tar.gz). 7-day rotation. The audit log Postgres is included via `make backup-v2` (Phase 6.x).

## Cost expectations

Per-call cost (1K input / 500 output tokens), routed through OpenRouter:

| Iris alias | Backend | $/call |
|---|---|---|
| `iris-cheap` | Qwen3.6 Plus | $0.0013 |
| `iris-briefing` | Gemini 3 Flash | $0.002 |
| `iris-marketing` | Kimi K2.6 | $0.0025 |
| `iris-default` | Kimi K2.6 (orchestrator) | $0.0025 |
| `iris-coding` | GLM-5.1 | $0.0028 |
| `iris-research` | Claude Opus 4.7 (escalation only) | $0.0175 |
| `iris-private` | Ollama (local) | free |
| Claude Code sidecar | Your Max plan | included in subscription |

Daily orchestration with ~50 default-tier calls + 10 coding + 5 research ≈ **$0.30/day** on OpenRouter, plus your Max plan subscription if using the Claude Code sidecar.

LiteLLM dashboard at http://127.0.0.1:4000/ui (login with `LITELLM_MASTER_KEY` from `litellm/.env`) shows per-call audit + spend.

## Privacy & guardrails

- **All cloud routes go through Presidio** — credit cards, SSNs, IBANs are blocked entirely; emails and phones are masked with placeholders before reaching the upstream model
- **`iris-private` route never leaves your machine** — local Ollama (qwen2.5:32b)
- **Claude Code sidecar has 4 hook layers**: prompt CC/SSN block, filename deny-list (`.env`, `.pem`, `.ssh/`, etc.), write-side secret detector (AWS/GitHub/Stripe/Anthropic key shapes), and a post-read PII context-injector that warns Claude not to echo found PII
- **Backend networks are `internal: true`** — databases, redis, presidio, honcho-api have no internet access and aren't exposed to the host
- **Virtual keys** isolate Iris from real provider credentials; Iris never sees your OpenRouter key

Honest scope: the Claude Code sidecar can read arbitrary files in `/workspace`, and the public Claude Code hook API doesn't permit content masking before Anthropic sees it. Workspace hygiene is the primary defense — don't put secrets in `~/iris-workspace`.

## Letting Iris evolve itself (optional)

Iris has read+write access to her own repo at `/repo` inside the container, and can commit changes to `iris-self/*` or `iris-proposed/*` branches with auto-enforced guardrails (no secrets, no personal data, no touching infra files, no push). To enable this, install the pre-commit + commit-msg hooks once after cloning:

```bash
bash scripts/install-iris-hooks.sh
```

Then your daily workflow when Iris proposes changes:

```bash
make iris-review     # see all pending iris-self/* and iris-proposed/* branches with diffs
make iris-push       # publish them to GitHub for review (you merge via PR)
make iris-clean      # destructive: delete all iris-* branches (after typing DELETE)
```

Push to `main` stays human-only. Full setup walkthrough in [INSTALL.md Phase I](INSTALL.md).

## Customizing Claude Code sidecar config

The container's Claude Code config (CLAUDE.md, rules, agents, skills, settings.json with hooks pre-wired) lives in `claude-cli/iris-config/` and is **baked into the image at build time**. To add your own:

```bash
# Edit the source files
$EDITOR claude-cli/iris-config/CLAUDE.md
$EDITOR claude-cli/iris-config/rules/your-new-rule.md

# Rebuild + recreate
docker compose build claude-cli
docker compose up -d claude-cli --force-recreate
```

The entrypoint only seeds new files into the live container if the destination is missing or empty — your runtime additions inside the container are preserved.

## Production deployment

```bash
make prod    # uses compose.prod.yaml: cap_drop ALL, no-new-privileges, read_only fs, log rotation
```

For a cloud VPS, you'd also want to swap the host-loopback `ports:` bindings (`127.0.0.1:9119`, etc.) for a reverse proxy (Caddy / Traefik) with proper auth in front.

For corporate / multi-tenant deployment (OIDC, RBAC, Vault, per-tenant pgvector, K8s manifests), the architectural deltas are documented in [PHASE_7_TENANCY.md](PHASE_7_TENANCY.md) — that's a 1-2 month platform build, sequenced as 8 migration steps. Don't reach for it until you actually need it (PHASE_7 lays out the "when to actually do this" criteria).

For per-task sandbox isolation (failed installs cannot break the gateway, blast radius limited to one execution), see [PHASE_5_SANDBOX.md](PHASE_5_SANDBOX.md) — the decision tree (firejail / Daytona / E2B / K8s Agent Sandbox) depends on threat model and infra.

## Want to know more

- **[V2_INSTALL.md](V2_INSTALL.md)** — the full V2 architecture spec (5 planes, 7 phases) with file layouts, env vars, network topology, and the V1→V2 migration runbook. Start here if a step in this README didn't work, or if you want to understand what each container does in depth.
- **[PHASE_5_SANDBOX.md](PHASE_5_SANDBOX.md)** — sandbox runtime decision tree + dispatcher API surface.
- **[PHASE_7_TENANCY.md](PHASE_7_TENANCY.md)** — corporate / multi-tenant reference architecture.
- **[INSTALL.md](INSTALL.md)** — the V1 install guide; still accurate for the V1 substrate that V2 builds on.

## License

This repo is your own composition of upstream projects. Each upstream keeps its own license:
- Hermes Agent: see `hermes-agent/LICENSE`
- Honcho: Apache 2.0
- LiteLLM: MIT
- Presidio: MIT
- Ollama, Claude Code, Anthropic SDKs: see their respective sites
