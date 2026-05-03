# Iris Agent Stack — Install Guide

**For most users: read [README.md](./README.md) first.** It has an 8-command quickstart that handles the common path.

**This file is the deep, phase-by-phase reproducible install** — every decision, every gotcha, every troubleshooting case. Read it if a quickstart step didn't work, if you want to understand the architecture, or if you're modifying the stack and need to know why each piece is the way it is.

**Read this entire file before doing anything.** Then execute phases in order. After each phase, stop and confirm with the user before proceeding.

---

## Working pattern

For every phase below:

1. Read the phase fully before acting
2. Run the commands in order
3. Show the user any file you're about to write **before** writing it
4. After the phase completes, run the verification step
5. Stop and ask the user to confirm before moving to the next phase

Don't batch phases. Don't skip verification. If something breaks, stop and report — don't try multiple fixes in sequence without confirmation.

---

## Architectural context (read first, don't relitigate)

Four-service stack on Mac M1, designed to also work on a cloud Linux VPS later:

- **Iris** — agent runtime, built from NousResearch/hermes-agent (upstream is named "Hermes"; we wrap it as Iris)
- **LiteLLM** (BerriAI/litellm) — privacy router, virtual keys, audit, budgets, guardrails
- **Honcho** (plastic-labs/honcho) — semantic memory layer with pgvector
- **Prometheus** — metrics scraper for LiteLLM

Three Docker bridge networks:

- `frontend` — published to 127.0.0.1; user-facing UIs only
- `backend` — `internal: true`; service-to-service only
- `data` — `internal: true`; only backend services attach; holds DBs and Redis

Compose layout uses the `include:` directive — each project owns a `compose.yaml` under its own subdirectory. Three top-level files: `compose.yaml` (small, just includes + networks), `compose.override.yaml` (dev, auto-loaded), `compose.prod.yaml` (prod hardening, opt-in via `-f`).

Decisions already made (don't propose alternatives unless something breaks):

- LiteLLM in front of OpenRouter (single cloud provider) + local Ollama. Anthropic / OpenAI / Google / Moonshot / Z.AI / Qwen are all reached via OpenRouter, so we manage exactly one cloud API key.
- DeepSeek family **excluded** from virtual aliases — 94-96% hallucination rate on unknown facts (BridgeBench). DeepSeek is also absent from the upstream Hermes curated catalog.
- **Variant U virtual alias picks** (community + benchmark validated):
  - `iris-default` → `moonshotai/kimi-k2.6` — upstream Hermes ⭐-tagged "recommended"
  - `iris-cheap` → `qwen/qwen3.6-plus` — #3 MCP-Atlas, 1M ctx, $0.33/$1.95
  - `iris-research` → `anthropic/claude-opus-4.7` — #1 MCP-Atlas, escalation route
  - `iris-coding` → `z-ai/glm-5.1` — first open-weight to top SWE-bench Pro
  - `iris-marketing` → `moonshotai/kimi-k2.6` — same backend as default, distinct alias for budget tracking
  - `iris-briefing` → `google/gemini-3-flash-preview` — cheap stable summarization
  - `iris-private` → local `qwen2.5:32b` via Ollama — never leaves the machine
- Fallback policy: "Opus only when Kimi doesn't work" — `iris-default` (Kimi) escalates directly to `iris-research` (Opus 4.7) on errors.
- Guardrails (Presidio PII + secret detection) deferred to a follow-up phase — they require a separate Presidio service and the modern LiteLLM top-level format.
- NemoClaw / OpenShell — NOT on Mac (Landlock unavailable). Future cloud only.
- Honcho self-hosted, NOT Plastic Labs hosted
- Three-file compose pattern with `include:`

---

## Pre-flight checks

Before Phase A, verify environment:

```bash
docker --version           # need Docker Desktop running on Mac
docker compose version     # need Compose v2.20+ for include: directive
git --version
openssl version            # for password generation
```

If `docker compose version` is older than v2.20, the `include:` directive won't work. Tell the user to update Docker Desktop and stop.

Also check the install directory:

```bash
ls -la ~/iris 2>/dev/null
```

The directory already exists and contains `INSTALL.md` — that's expected. If anything else is present that isn't accounted for in this guide, ask the user before proceeding.

---

## Phase A — Bootstrap directory structure

**Goal:** Create directory structure, clone upstream repos, init git.

### A.1 — Create directories

```bash
mkdir -p ~/iris/{iris,litellm,honcho,.docs}
cd ~/iris
```

### A.2 — Clone upstream repos

These are needed as Docker build contexts:

```bash
cd ~/iris
git clone --depth 1 https://github.com/NousResearch/hermes-agent.git
git clone --depth 1 https://github.com/plastic-labs/honcho.git honcho-src
```

The `--depth 1` keeps clones shallow (faster, smaller). The Honcho clone is named `honcho-src/` because `honcho/` is already used for our own compose file.

### A.3 — Init git for the stack itself

```bash
cd ~/iris
git init
```

Create `.gitignore`:

```bash
cat > .gitignore <<'EOF'
# ─────────── Secrets — NEVER commit ───────────
.env
.env.*
**/.env
**/.env.*
!.env.example
!**/.env.example

# Credentials, keys, tokens
*.pem
*.key
*.crt
*.p12
*.pfx
*.token
*.secret
secrets/
credentials/
service-account*.json
auth.json

# ─────────── Upstream clones — managed separately ───────────
hermes-agent/
honcho-src/

# ─────────── Heavy data / backups ───────────
backups/
*.sql
*.sql.gz
*.dump
*.bak
*.tar
*.tar.gz
*.tgz
*.zip

# Local DB files (named Docker volumes don't escape, but bind mounts might)
*.sqlite
*.sqlite3
*.db

# ML / model artifacts (Ollama cache, GGUF blobs, weights)
*.gguf
*.bin
*.safetensors
*.onnx
*.pt
*.ckpt
models/
.ollama/

# ─────────── Python (defensive, in case scripts/ grows) ───────────
__pycache__/
*.py[cod]
*.egg-info/
.venv/
venv/
.pytest_cache/
.mypy_cache/
.ruff_cache/

# ─────────── Logs ───────────
*.log
logs/

# ─────────── Local Claude Code state ───────────
.claude/

# ─────────── OS / editor noise ───────────
.DS_Store
Thumbs.db
.vscode/
.idea/
*.swp
*.swo
*~

# ─────────── Local-only compose overrides ───────────
compose.local.yaml
docker-compose.local.yml
EOF
```

Note: `env.example` (no leading dot) is the convention used in this repo — it's not matched by any `.env*` pattern above, so it's tracked by default. The `!.env.example` lines remain as defensive un-ignores in case a `.env.example` is ever created (e.g., copied from another project).

### A.4 — Verify

```bash
ls -la ~/iris
ls ~/iris/hermes-agent/Dockerfile
ls ~/iris/honcho-src/Dockerfile
```

Both Dockerfiles must exist. If either is missing, the upstream repo structure changed — stop and tell the user.

**STOP. Confirm with user before Phase B.**

---

## Phase B — Write compose files

**Goal:** Create all compose files. Don't run anything yet.

### B.1 — Top-level `compose.yaml`

Path: `~/iris/compose.yaml`

```yaml
name: iris

include:
  - ./iris/compose.yaml
  - ./litellm/compose.yaml
  - ./honcho/compose.yaml

networks:
  frontend:
    driver: bridge
  backend:
    driver: bridge
    internal: true
  data:
    driver: bridge
    internal: true
```

### B.2 — `iris/compose.yaml`

Path: `~/iris/iris/compose.yaml`

```yaml
volumes:
  iris_data:

services:
  iris-gateway:
    build: ../hermes-agent
    image: iris:local
    container_name: iris-gateway
    restart: unless-stopped
    volumes:
      - iris_data:/opt/data
    environment:
      HERMES_UID: ${HERMES_UID:-10000}
      HERMES_GID: ${HERMES_GID:-10000}
    extra_hosts:
      - "host.docker.internal:host-gateway"
    networks:
      - backend
    command: ["gateway", "run"]

  iris-dashboard:
    image: iris:local
    container_name: iris-dashboard
    restart: unless-stopped
    depends_on:
      - iris-gateway
    volumes:
      - iris_data:/opt/data
    environment:
      HERMES_UID: ${HERMES_UID:-10000}
      HERMES_GID: ${HERMES_GID:-10000}
    networks:
      - frontend
      - backend
    ports:
      - "127.0.0.1:9119:9119"
    # --insecure is required because we bind to 0.0.0.0 inside the container.
    # Safe here: compose publishes port 9119 only to host 127.0.0.1, not 0.0.0.0.
    command: ["dashboard", "--host", "0.0.0.0", "--no-open", "--insecure"]
```

### B.3 — `litellm/compose.yaml`

Path: `~/iris/litellm/compose.yaml`

```yaml
volumes:
  litellm_postgres_data:
  prometheus_data:

services:
  litellm:
    image: docker.litellm.ai/berriai/litellm:main-stable
    container_name: litellm
    restart: unless-stopped
    volumes:
      - ./config.yaml:/app/config.yaml:ro
    command:
      - "--config=/app/config.yaml"
    environment:
      DATABASE_URL: "postgresql://llmproxy:${LITELLM_DB_PASSWORD}@litellm-db:5432/litellm"
      STORE_MODEL_IN_DB: "True"
    env_file:
      - ./.env
    depends_on:
      litellm-db:
        condition: service_healthy
    networks:
      - frontend
      - backend
      - data
    ports:
      - "127.0.0.1:4000:4000"
    healthcheck:
      test:
        - CMD-SHELL
        - python3 -c "import urllib.request; urllib.request.urlopen('http://localhost:4000/health/liveliness')"
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s

  litellm-db:
    image: postgres:16
    container_name: litellm-db
    restart: unless-stopped
    environment:
      POSTGRES_DB: litellm
      POSTGRES_USER: llmproxy
      POSTGRES_PASSWORD: ${LITELLM_DB_PASSWORD}
    volumes:
      - litellm_postgres_data:/var/lib/postgresql/data
    networks:
      - data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -d litellm -U llmproxy"]
      interval: 1s
      timeout: 5s
      retries: 10

  prometheus:
    image: prom/prometheus
    container_name: prometheus
    restart: unless-stopped
    volumes:
      - prometheus_data:/prometheus
      - ./prometheus.yml:/etc/prometheus/prometheus.yml:ro
    command:
      - "--config.file=/etc/prometheus/prometheus.yml"
      - "--storage.tsdb.path=/prometheus"
      - "--storage.tsdb.retention.time=15d"
    networks:
      - frontend
      - backend
    ports:
      - "127.0.0.1:9090:9090"
```

### B.4 — `honcho/compose.yaml`

Path: `~/iris/honcho/compose.yaml`

**Important caveat:** The `honcho-deriver` service assumes upstream Honcho launches the deriver as `python -m src.deriver`. Some Honcho versions run the deriver inside the API container via `entrypoint.sh`. **Before running**, inspect `~/iris/honcho-src/docker/entrypoint.sh`:

```bash
cat ~/iris/honcho-src/docker/entrypoint.sh
```

If the entrypoint already spawns the deriver internally, comment out the entire `honcho-deriver` service in the file below. Tell the user what you found and ask before proceeding.

```yaml
volumes:
  honcho_pgdata:

services:
  honcho-api:
    build:
      context: ../honcho-src
      dockerfile: Dockerfile
    image: honcho:local
    container_name: honcho-api
    entrypoint: ["sh", "docker/entrypoint.sh"]
    restart: unless-stopped
    depends_on:
      honcho-db:
        condition: service_healthy
      honcho-redis:
        condition: service_healthy
    environment:
      DB_CONNECTION_URI: "postgresql+psycopg://postgres:${HONCHO_DB_PASSWORD}@honcho-db:5432/postgres"
      CACHE_URL: "redis://honcho-redis:6379/0?suppress=true"
      CACHE_ENABLED: "true"
    env_file:
      - path: ../honcho-src/.env
        required: false
    # frontend = outbound internet for tiktoken tokenizer fetch + future LLM API calls.
    # No `ports:` block — service is not exposed inbound, only egress is enabled.
    networks:
      - frontend
      - backend
      - data

  honcho-deriver:
    image: honcho:local
    container_name: honcho-deriver
    restart: unless-stopped
    depends_on:
      honcho-api:
        condition: service_started
    environment:
      DB_CONNECTION_URI: "postgresql+psycopg://postgres:${HONCHO_DB_PASSWORD}@honcho-db:5432/postgres"
      CACHE_URL: "redis://honcho-redis:6379/0?suppress=true"
      CACHE_ENABLED: "true"
    env_file:
      - path: ../honcho-src/.env
        required: false
    # frontend for tokenizer + outbound LLM API calls (same as honcho-api).
    networks:
      - frontend
      - backend
      - data
    entrypoint: []
    command: ["python", "-m", "src.deriver"]

  honcho-db:
    image: pgvector/pgvector:pg15
    container_name: honcho-db
    restart: unless-stopped
    command: ["postgres", "-c", "max_connections=200"]
    environment:
      POSTGRES_DB: postgres
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: ${HONCHO_DB_PASSWORD}
      PGDATA: /var/lib/postgresql/data/pgdata
    volumes:
      - ../honcho-src/database/init.sql:/docker-entrypoint-initdb.d/init.sql:ro
      - honcho_pgdata:/var/lib/postgresql/data/
    networks:
      - data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres -d postgres"]
      interval: 5s
      timeout: 5s
      retries: 5

  honcho-redis:
    image: redis:8.2
    container_name: honcho-redis
    restart: unless-stopped
    networks:
      - data
    healthcheck:
      test: ["CMD-SHELL", "redis-cli ping"]
      interval: 5s
      timeout: 3s
      retries: 5
```

### B.5 — `compose.override.yaml` (dev defaults, auto-loaded)

Path: `~/iris/compose.override.yaml`

```yaml
services:
  iris-gateway:
    environment:
      LOG_LEVEL: debug
      HERMES_DEBUG: "true"

  litellm:
    command:
      - "--config=/app/config.yaml"
      - "--detailed_debug"
    environment:
      LITELLM_LOG: DEBUG

  honcho-api:
    environment:
      LOG_LEVEL: DEBUG

  honcho-deriver:
    environment:
      LOG_LEVEL: DEBUG
```

### B.6 — `compose.prod.yaml` (prod hardening, opt-in)

Path: `~/iris/compose.prod.yaml`

```yaml
x-app-hardening: &app-hardening
  security_opt:
    - "no-new-privileges:true"
  cap_drop:
    - ALL
  restart: always
  logging:
    driver: json-file
    options:
      max-size: "10m"
      max-file: "5"

x-db-hardening: &db-hardening
  security_opt:
    - "no-new-privileges:true"
  restart: always
  logging:
    driver: json-file
    options:
      max-size: "10m"
      max-file: "5"

services:
  iris-gateway:
    <<: *app-hardening
    read_only: true
    tmpfs:
      - /tmp:size=128M,mode=1777

  iris-dashboard:
    <<: *app-hardening
    read_only: true
    tmpfs:
      - /tmp:size=64M,mode=1777

  litellm:
    <<: *app-hardening
    read_only: true
    tmpfs:
      - /tmp:size=128M,mode=1777
      - /app/cache:size=128M,mode=1777

  litellm-db:
    <<: *db-hardening

  prometheus:
    <<: *db-hardening

  honcho-api:
    <<: *app-hardening
    read_only: true
    tmpfs:
      - /tmp:size=128M,mode=1777

  honcho-deriver:
    <<: *app-hardening
    read_only: true
    tmpfs:
      - /tmp:size=128M,mode=1777

  honcho-db:
    <<: *db-hardening

  honcho-redis:
    <<: *db-hardening
```

### B.7 — `Makefile`

Path: `~/iris/Makefile`

**Critical:** Makefiles use TAB characters for indentation, not spaces. When writing this file, use literal tabs.

```makefile
.PHONY: help up dev prod down logs ps config config-prod rebuild pull clean backup

BASE := compose.yaml
DEV  := compose.override.yaml
PROD := compose.prod.yaml

help:               ## show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

up: dev             ## alias for `make dev`

dev:                ## start dev stack (base + override, auto-merged)
	docker compose up -d

prod:               ## start prod stack (base + prod hardening)
	docker compose -f $(BASE) -f $(PROD) up -d

down:               ## stop everything (volumes preserved)
	docker compose down

logs:               ## tail logs; pass SERVICE=name to filter
	docker compose logs -f $(SERVICE)

ps:                 ## show running containers
	docker compose ps

config:             ## preview merged dev config
	docker compose config

config-prod:        ## preview merged prod config
	docker compose -f $(BASE) -f $(PROD) config

rebuild:            ## rebuild local images (Iris, Honcho)
	docker compose build --no-cache iris-gateway honcho-api

pull:               ## pull updated upstream images
	docker compose pull litellm litellm-db prometheus honcho-db honcho-redis

backup:             ## dump databases and iris_data to ./backups/
	@bash scripts/backup.sh

clean:              ## stop + remove volumes (DESTROYS data)
	@read -p "Type DELETE to confirm volume deletion: " confirm && [ "$$confirm" = "DELETE" ] && docker compose down -v
```

### B.8 — `env.example`

Path: `~/iris/env.example`

```bash
# ──────────────── Container UID/GID ────────────────
# So Iris-created files in volumes are owned by host user.
# (Variable names stay HERMES_* because the upstream container reads them.)
# Get your values with: id -u  /  id -g
HERMES_UID=501
HERMES_GID=20

# ──────────────── Database passwords ────────────────
# Generate strong values: openssl rand -hex 32
LITELLM_DB_PASSWORD=replace-me-with-openssl-rand-hex-32
HONCHO_DB_PASSWORD=replace-me-with-openssl-rand-hex-32
```

### B.9 — `litellm/env.example`

Path: `~/iris/litellm/env.example`

```bash
# LiteLLM master and salt keys
# Master key — generate with: openssl rand -hex 32
# Salt key — generate ONCE; never change after adding models
LITELLM_MASTER_KEY=sk-replace-me
LITELLM_SALT_KEY=sk-replace-me

# Single provider key — all cloud routes go through OpenRouter.
# Get from: https://openrouter.ai/keys
OPENROUTER_API_KEY=sk-or-...
```

### B.10 — `litellm/prometheus.yml`

Path: `~/iris/litellm/prometheus.yml`

```yaml
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: 'litellm'
    static_configs:
      - targets: ['litellm:4000']
    metrics_path: '/metrics'
```

### B.11 — `litellm/config.yaml`

Path: `~/iris/litellm/config.yaml`

This is the most consequential file. It defines the model_list (real backends + virtual aliases the agent uses) and the fallback chains. Picks reflect the live Hermes upstream curated catalog at https://hermes-agent.nousresearch.com/docs/api/model-catalog.json (rank-ordered, Kimi K2.6 ⭐-tagged "recommended"), validated against MCP-Atlas and EQ-Creative benchmarks.

All cloud routing goes through OpenRouter — only one provider key is needed. Local Ollama handles privacy-sensitive prompts.

```yaml
# LiteLLM proxy config — all routes via OpenRouter except local Ollama.
# Real provider key lives in litellm/.env (only OPENROUTER_API_KEY needed).
# Iris never sees the OpenRouter key — it uses virtual LiteLLM keys instead.
#
# Picks reflect the Hermes upstream curated catalog (April 30, 2026):
#   https://hermes-agent.nousresearch.com/docs/api/model-catalog.json
# Rank-ordered: Kimi K2.6 ⭐ recommended → Opus 4.7 → Sonnet 4.6 → Qwen3.6 Plus → Haiku 4.5 → GPT-5.5
# DeepSeek excluded from this config (94-96% hallucination rate; also absent from upstream catalog).

model_list:
  # ─────────── Real backends (direct model access) ───────────
  - model_name: claude-opus
    litellm_params:
      model: openrouter/anthropic/claude-opus-4.7
      api_key: os.environ/OPENROUTER_API_KEY

  - model_name: claude-sonnet
    litellm_params:
      model: openrouter/anthropic/claude-sonnet-4.6
      api_key: os.environ/OPENROUTER_API_KEY

  - model_name: claude-haiku
    litellm_params:
      model: openrouter/anthropic/claude-haiku-4.5
      api_key: os.environ/OPENROUTER_API_KEY

  - model_name: gpt-5
    litellm_params:
      model: openrouter/openai/gpt-5.5
      api_key: os.environ/OPENROUTER_API_KEY

  - model_name: gpt-5-mini
    litellm_params:
      model: openrouter/openai/gpt-5-mini
      api_key: os.environ/OPENROUTER_API_KEY

  - model_name: gemini-pro
    litellm_params:
      model: openrouter/google/gemini-3.1-pro-preview
      api_key: os.environ/OPENROUTER_API_KEY

  - model_name: gemini-flash
    litellm_params:
      model: openrouter/google/gemini-3-flash-preview
      api_key: os.environ/OPENROUTER_API_KEY

  - model_name: kimi
    litellm_params:
      model: openrouter/moonshotai/kimi-k2.6
      api_key: os.environ/OPENROUTER_API_KEY

  - model_name: qwen-plus
    litellm_params:
      model: openrouter/qwen/qwen3.6-plus
      api_key: os.environ/OPENROUTER_API_KEY

  - model_name: glm
    litellm_params:
      model: openrouter/z-ai/glm-5.1
      api_key: os.environ/OPENROUTER_API_KEY

  # Local Ollama on host Mac — reaches via host.docker.internal (extra_hosts in compose)
  - model_name: ollama-local
    litellm_params:
      model: ollama_chat/qwen2.5:32b
      api_base: http://host.docker.internal:11434

  # ─────────── Virtual aliases (logical names Iris uses) ───────────

  # iris-default — primary orchestrator. Kimi K2.6 is upstream Hermes ⭐ recommended.
  # Hermes v0.11/v0.12 ship Kimi-specific tool-call patches (PRs 13148, 15749, 15762, 18045).
  # 39% hallucination (Opus territory). 6.7x cheaper than Opus 4.7.
  # Falls back to Opus on errors (see router_settings below).
  - model_name: iris-default
    litellm_params:
      model: openrouter/moonshotai/kimi-k2.6
      api_key: os.environ/OPENROUTER_API_KEY

  # iris-cheap — high-volume verifiable tasks. Qwen3.6 Plus: #3 MCP-Atlas (0.741),
  # #1 MCPMark tool-calling (48.2%), 1M ctx. Caveat: 26.5% fabrication on API knowledge —
  # only route work where outputs are validated (tool results, code with tests, structured extraction).
  - model_name: iris-cheap
    litellm_params:
      model: openrouter/qwen/qwen3.6-plus
      api_key: os.environ/OPENROUTER_API_KEY

  # iris-research — escalation route for ambiguous planning, deep analysis, top-tier reasoning.
  # Opus 4.7: #1 MCP-Atlas (0.773), #1 SWE-Verified (87.6%), top EQ-Creative (Elo 2216), 1M ctx.
  - model_name: iris-research
    litellm_params:
      model: openrouter/anthropic/claude-opus-4.7
      api_key: os.environ/OPENROUTER_API_KEY

  # iris-private — local Ollama only. Never leaves the machine. Use for sensitive prompts.
  - model_name: iris-private
    litellm_params:
      model: ollama_chat/qwen2.5:32b
      api_base: http://host.docker.internal:11434

  # iris-marketing — creative writing / copy. Same backend as iris-default (Kimi K2.6,
  # EQ-Creative 1808) — kept as a separate alias for budget tracking and future re-routing.
  - model_name: iris-marketing
    litellm_params:
      model: openrouter/moonshotai/kimi-k2.6
      api_key: os.environ/OPENROUTER_API_KEY

  # iris-coding — daily code workflow with tool calls. GLM-5.1: first open-weight to top
  # SWE-bench Pro (58.4%), #5 MCP-Atlas (0.718), upstream-curated. 200K ctx — Hermes
  # compression handles longer codebases.
  - model_name: iris-coding
    litellm_params:
      model: openrouter/z-ai/glm-5.1
      api_key: os.environ/OPENROUTER_API_KEY

  # iris-briefing — daily summaries (long input, short output). Gemini 3 Flash:
  # $0.50/$3, 1M ctx, stable OpenRouter throughput. Compat-layer issues only affect
  # tool-calling / streaming, not batch summarization.
  - model_name: iris-briefing
    litellm_params:
      model: openrouter/google/gemini-3-flash-preview
      api_key: os.environ/OPENROUTER_API_KEY

litellm_settings:
  # Prompt caching — saves ~90% on cached input tokens for Anthropic family
  cache: true
  cache_params:
    type: local

  # Drop unsupported params silently rather than erroring
  drop_params: true

  # Telemetry off
  telemetry: false
  set_verbose: false

  # Guardrails (Presidio PII + secret detection) deferred — they require a separate
  # Presidio service to be deployed and the modern LiteLLM format expects guardrails
  # at the top level. Re-enable as a top-level `guardrails:` block once Presidio is wired in.

general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY
  database_url: os.environ/DATABASE_URL
  store_model_in_db: true
  store_prompts_in_spend_logs: true

router_settings:
  routing_strategy: "simple-shuffle"
  num_retries: 2
  timeout: 60

  # Fallback chains — "Opus only when Kimi doesn't work" policy.
  # Default escalates directly to Opus on errors. Other aliases fall back to Kimi default.
  fallbacks:
    - iris-default: ["iris-research"]            # Kimi -> Opus when Kimi fails
    - iris-research: ["iris-default"]            # Opus -> Kimi (cost saver if Opus rate-limited)
    - iris-coding: ["iris-default", "iris-research"]   # GLM -> Kimi -> Opus
    - iris-marketing: ["iris-research"]          # Kimi -> Opus (same primary as default)
    - iris-cheap: ["iris-default"]               # Qwen -> Kimi
    - iris-briefing: ["iris-default"]            # Gemini Flash -> Kimi
```

**Re-validating slugs before deploy:** OpenRouter slugs change. Before pasting this file, run:
```bash
curl -s https://openrouter.ai/api/v1/models | python3 -c "
import json,sys; ids={m['id'] for m in json.load(sys.stdin)['data']}
for s in ['anthropic/claude-opus-4.7','anthropic/claude-sonnet-4.6','anthropic/claude-haiku-4.5','openai/gpt-5.5','openai/gpt-5-mini','google/gemini-3.1-pro-preview','google/gemini-3-flash-preview','moonshotai/kimi-k2.6','qwen/qwen3.6-plus','z-ai/glm-5.1']:
  print('OK ' if s in ids else 'MISSING ', s)"
```
If any slug shows MISSING, look up the current name on OpenRouter and update before continuing.

### B.12 — Verify all files exist

```bash
cd ~/iris
ls -la compose.yaml compose.override.yaml compose.prod.yaml Makefile env.example
ls -la iris/compose.yaml
ls -la litellm/compose.yaml litellm/env.example litellm/prometheus.yml litellm/config.yaml
ls -la honcho/compose.yaml
```

All ten files must exist. Then validate the compose merges:

```bash
# This will fail until .env exists, which is fine — we just want the syntax check
docker compose config 2>&1 | head -20
```

If the error is about missing env variables (`LITELLM_DB_PASSWORD`, etc.), that's expected — Phase D will create `.env`. If the error is about YAML syntax or missing includes, fix those before proceeding.

**STOP. Confirm with user before Phase C.**

---

## Phase C — Generate secrets and `.env` files

**Goal:** Populate `.env` files with real secrets. The user provides provider API keys interactively.

### C.1 — Top-level `.env`

```bash
cd ~/iris
cp env.example .env

# Generate DB passwords
LITELLM_DB_PW=$(openssl rand -hex 32)
HONCHO_DB_PW=$(openssl rand -hex 32)

# Get host UID/GID
HOST_UID=$(id -u)
HOST_GID=$(id -g)

# Write to .env using sed (works on both Mac and Linux)
sed -i.bak "s|HERMES_UID=501|HERMES_UID=$HOST_UID|" .env
sed -i.bak "s|HERMES_GID=20|HERMES_GID=$HOST_GID|" .env
sed -i.bak "s|LITELLM_DB_PASSWORD=replace-me-with-openssl-rand-hex-32|LITELLM_DB_PASSWORD=$LITELLM_DB_PW|" .env
sed -i.bak "s|HONCHO_DB_PASSWORD=replace-me-with-openssl-rand-hex-32|HONCHO_DB_PASSWORD=$HONCHO_DB_PW|" .env
rm .env.bak
```

Verify:

```bash
cat ~/iris/.env
```

The four values should now be populated. Don't echo this in chat — show the user that it's done without revealing the secrets.

### C.2 — `litellm/.env`

```bash
cd ~/iris/litellm
cp env.example .env

LITELLM_MASTER=$(openssl rand -hex 32)
LITELLM_SALT=$(openssl rand -hex 32)

sed -i.bak "s|LITELLM_MASTER_KEY=sk-replace-me|LITELLM_MASTER_KEY=sk-$LITELLM_MASTER|" .env
sed -i.bak "s|LITELLM_SALT_KEY=sk-replace-me|LITELLM_SALT_KEY=sk-$LITELLM_SALT|" .env
rm .env.bak
```

Then **ask the user** for one provider API key:

```
I need your OpenRouter API key (starts with sk-or-).
Get it from: https://openrouter.ai/keys

For privacy, paste it inline using the ! prefix so it goes straight to the shell
without the LLM seeing it. I'll write it to litellm/.env directly. Run:

  ! sed -i.bak "s|OPENROUTER_API_KEY=sk-or-\.\.\.|OPENROUTER_API_KEY=YOUR_KEY|" ~/iris/litellm/.env && rm ~/iris/litellm/.env.bak && echo "✓ key written"

Note: even with `!`, the key still lands in the conversation transcript. Rotate it
on https://openrouter.ai/keys after install if you want to be belt-and-braces safe.
```

After the key is written:

```bash
cd ~/iris/litellm
grep -E "^(LITELLM|OPENROUTER)" .env | awk -F= '{ printf "%s=<%d-char-value>\n", $1, length($2) }'
# Expect three lines, all with non-zero lengths.
```

### C.3 — Verify compose merges cleanly

```bash
cd ~/iris
docker compose config > /dev/null && echo "✓ compose config OK"
```

If this fails, the env interpolation broke. Show the error and stop.

**STOP. Confirm with user before Phase D.**

---

## Phase D — Install Ollama (for local model)

**Goal:** Ensure Ollama is running on the host so the `iris-private` virtual model has a backend to route to.


### D.1 — Check if Ollama is installed

```bash
which ollama || echo "not installed"
```

If not installed:

```bash
# Universal (works on macOS + Linux)
curl -fsSL https://ollama.com/install.sh | sh

# OR, on macOS specifically:
brew install ollama
```

### D.2 — Start Ollama service

```bash
# macOS (Homebrew install):
brew services start ollama

# Linux (curl install — uses systemd):
sudo systemctl start ollama && sudo systemctl enable ollama

# Either way, verify:
sleep 3
curl http://localhost:11434/api/tags && echo "✓ Ollama responding"
```

### D.3 — Pull the local model

```bash
ollama pull qwen2.5:32b
```

This is ~19 GB — takes 10-30 minutes depending on network. (We picked the 32B variant over 14B because most M1/M2 Mac setups handle it fine and the quality lift on private/local prompts is meaningful.) The model name in `litellm/config.yaml` (B.11) is `qwen2.5:32b` — if the user wants a different local model, update both places.

### D.4 — Verify reachable from Docker

This is critical. Iris/LiteLLM containers reach Ollama via `host.docker.internal:11434`. Verify the routing works:

```bash
docker run --rm --add-host=host.docker.internal:host-gateway alpine \
  sh -c "apk add curl -q && curl -s http://host.docker.internal:11434/api/tags"
```

If this fails, Ollama isn't reachable from containers — likely binding to `127.0.0.1:11434` instead of `0.0.0.0:11434`. Fix:

```bash
# macOS:
launchctl setenv OLLAMA_HOST 0.0.0.0
brew services restart ollama

# Linux (systemd):
sudo systemctl edit ollama   # add: [Service]\n  Environment="OLLAMA_HOST=0.0.0.0"
sudo systemctl restart ollama
```

**STOP. Confirm with user before Phase E.**

---

## Phase E — Build and start the stack

**Goal:** Build local images, pull remote images, bring up all services, verify health.

### E.1 — Build local images

```bash
cd ~/iris
docker compose build iris-gateway honcho-api
```

This will take 10-20 minutes the first time. Iris especially is slow due to Playwright + Chromium. Watch for errors. If a build fails, tell the user the exact error and stop.

### E.2 — Pull remote images

```bash
cd ~/iris
docker compose pull litellm litellm-db prometheus honcho-db honcho-redis
```

Should be quick — maybe 2-5 minutes.

### E.3 — Bring up the stack

```bash
cd ~/iris
make dev
```

Then watch healthchecks:

```bash
watch -n 2 docker compose ps
```

All nine services should reach `running` and (where applicable) `healthy` within ~60 seconds. If any service is `restarting` or stays `unhealthy`, capture logs:

```bash
docker compose logs <service-name> --tail 50
```

Common failures and fixes:

| Symptom | Likely cause | Fix |
|---|---|---|
| `litellm` keeps restarting w/ `GuardrailItem ... must be a mapping, not str` | Old guardrails format under `litellm_settings:` | Already removed in B.11 above; if it reappears, ensure no nested `guardrails:` block under `litellm_settings:` (modern format is top-level list) |
| `litellm` keeps restarting (Postgres errors) | Postgres not ready | Check `docker compose logs litellm-db`; password mismatch likely |
| `honcho-api` / `honcho-deriver` crashloop with `Failed to resolve 'openaipublic.blob.core.windows.net'` | Honcho's tiktoken needs to fetch the BPE encoding once, but `backend`/`data` networks are `internal: true` | Already handled in B.4 — both services include the `frontend` network for outbound DNS/HTTP. If still failing, confirm the `frontend` entry is present under both `honcho-api.networks:` and `honcho-deriver.networks:` |
| `iris-dashboard` keeps restarting w/ `Refusing to bind to 0.0.0.0` | Dashboard refuses 0.0.0.0 without `--insecure` | Already handled in B.2 — `command: [..., "--insecure"]`. Safe in this setup because the host port maps only to `127.0.0.1:9119`, not to a public interface |
| `honcho-deriver` exits immediately | Wrong invocation | Check `~/iris/honcho-src/docker/entrypoint.sh`; may need to remove deriver service |
| `iris-dashboard` returns 500 | Gateway not started | Check `docker compose logs iris-gateway` |
| Build fails for Iris | Playwright deps issue | Try `docker compose build --no-cache iris-gateway` |
| `docker compose pull` / `build` errors with `input/output error` on `/var/lib/docker/...` | Docker Desktop VM disk exhausted (host disk too full) | Check `df -h /` — need at least 25 GB free for full install. Free space, restart Docker Desktop, retry |
| Service crashloops after editing `.env` and running `docker compose restart` | Compose only re-reads `env_file` at container creation, not on restart | Use `docker compose up -d <service> --force-recreate` instead. Verify with `docker compose exec -T <service> env \| grep VAR_NAME` |

### E.4 — Verify network isolation

These should **succeed** (frontend services published to host loopback):

```bash
curl -fs http://127.0.0.1:9119 > /dev/null && echo "✓ iris-dashboard reachable"
curl -fs http://127.0.0.1:4000/health/liveliness && echo "✓ litellm reachable"
curl -fs http://127.0.0.1:9090 > /dev/null && echo "✓ prometheus reachable"
```

These should **fail with connection refused** (backend/data services not exposed):

```bash
curl -fs --max-time 2 http://127.0.0.1:5432 && echo "✗ litellm-db is exposed (BAD)" || echo "✓ litellm-db isolated"
curl -fs --max-time 2 http://127.0.0.1:6379 && echo "✗ honcho-redis is exposed (BAD)" || echo "✓ honcho-redis isolated"
curl -fs --max-time 2 http://127.0.0.1:8000 && echo "✗ honcho-api is exposed (BAD)" || echo "✓ honcho-api isolated"
```

If anything reports BAD, the network config has a leak — likely a `ports:` entry that shouldn't be there. Stop and tell the user.

### E.5 — Verify service-to-service connectivity

From inside the Iris container, reach LiteLLM and Honcho:

```bash
docker compose exec iris-gateway sh -c "wget -qO- http://litellm:4000/health/liveliness"
docker compose exec iris-gateway sh -c "wget -qO- http://honcho-api:8000/health"
```

Both should return JSON. If either fails, it's a network membership issue — verify the service is on `backend` in its compose file.

**STOP. Confirm with user before Phase F.**

---

## Phase F — Mint a virtual key and test inference


**Goal:** Create a virtual key in LiteLLM, make one inference call, verify the privacy router works end-to-end.

### F.1 — Mint a virtual key for Iris

The master key is in `litellm/.env` as `LITELLM_MASTER_KEY`. Use it to mint a virtual key for Iris's default workflow:

```bash
MASTER=$(grep LITELLM_MASTER_KEY ~/iris/litellm/.env | cut -d= -f2)

curl -s -X POST http://127.0.0.1:4000/key/generate \
  -H "Authorization: Bearer $MASTER" \
  -H "Content-Type: application/json" \
  -d '{
    "key_alias": "iris-default",
    "models": ["iris-default", "iris-cheap", "iris-research", "iris-private", "iris-marketing", "iris-coding", "iris-briefing"],
    "max_budget": 50.00,
    "budget_duration": "30d",
    "rpm_limit": 60,
    "tpm_limit": 100000,
    "metadata": {"workflow": "iris"}
  }' | tee /tmp/iris-key.json
```

The response contains the new key. Extract it:

```bash
IRIS_VKEY=$(jq -r .key /tmp/iris-key.json)
echo "Virtual key minted: ${IRIS_VKEY:0:12}..."
```

### F.2 — Test the virtual key with a real inference call

`iris-default` routes to Kimi K2.6 (a reasoning model). Reasoning models consume tokens on internal thinking before emitting visible content — set `max_tokens` high enough (≥200) for both phases:

```bash
curl -s -X POST http://127.0.0.1:4000/v1/chat/completions \
  -H "Authorization: Bearer $IRIS_VKEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "iris-default",
    "messages": [{"role": "user", "content": "Reply with exactly the word: pong. Nothing else."}],
    "max_tokens": 200
  }' | jq
```

Expected: a chat completion response. The full chain validates: virtual key → LiteLLM → OpenRouter → Kimi K2.6 → response. If `choices[0].message.content` is `null` or empty but `usage.completion_tokens_details.reasoning_tokens` is non-zero, the model spent all tokens reasoning — increase `max_tokens` and retry.

### F.3 — Verify audit log captured the call

```bash
docker compose exec -T litellm-db psql -U llmproxy -d litellm -c \
  "SELECT call_type, model, model_group, total_tokens, spend, custom_llm_provider FROM \"LiteLLM_SpendLogs\" ORDER BY \"startTime\" DESC LIMIT 3;"
```

Expected:
- `model_group` = the alias Iris asked for (`iris-default`)
- `model` = the actual backend dispatched (`openrouter/moonshotai/kimi-k2.6`)
- `custom_llm_provider` = `openrouter`
- `spend` = USD cost of the call

(Column is `spend`, not `response_cost` — some older LiteLLM docs are stale. Verify with `\d "LiteLLM_SpendLogs"` if the query errors.)

### F.4 — Save the virtual key + apply the optimized Iris config

The full F.4 flow is automated by `scripts/mint-iris-key.sh`. It:
1. Mints the virtual key in LiteLLM if `IRIS_VIRTUAL_KEY` isn't already in `.env`
2. Renders `iris/iris-config/config.template.yaml` with the key substituted in
3. Writes the rendered config + the SOUL.md persona into `iris-gateway:/opt/data/`
4. Fixes file ownership (root → hermes:dialout)
5. Restarts iris-gateway

Just run:

```bash
bash scripts/mint-iris-key.sh
```

(Add `--force` to rotate the key.)

The Iris config that lands in `/opt/data/config.yaml` reflects three community-validated cost / performance optimizations:

| Setting | Value | Why |
|---|---|---|
| `prompt_caching.cache_ttl` | `1h` | Saves $400-850/mo for active users (per upstream issue #14971); 2× write cost amortizes over the session if 60%+ of writes become reads |
| `compression.threshold` | `0.50` | Compress at 50% of context window; protects last 20 messages |
| `auxiliary` (8-task block) | per-task model overrides | **50-70% aux-spend reduction** vs all-on-main (community-validated). compression+vision → `iris-briefing` (Gemini 3 Flash, vision-capable, fast summarization quality matters). title_gen / session_search / web_extract / skills_hub / mcp → `iris-cheap` (Qwen3.6 Plus, $0.33/$1.95) — these are classification-y. approval → `main` (security-relevant, keep quality high). |
| `skills.loading: lazy` | one-line skills catalog instead of all 89 skills inlined | Saves **~2K tokens off every system prompt** (per upstream issue #2045). At $3/M output × 100 calls/day = ~$0.60/day = **~$18/mo** input savings; comparable on output. Trade-off: agent calls `list_skills()` when it suspects a skill might help (one extra round trip). |
| `reasoning_effort: low` | Kimi K2.6 default tier from "medium" to "low" | Kimi K2.6 reasoning burns 1000+ tokens/turn at "medium". Cutting to "low" reduces by ~50% on routine work. User can escalate at runtime with `/reasoning high` for hard problems. ~**$15-30/mo savings** at moderate use. |
| `model.max_tokens: 4096` | output ceiling per turn | Default ceiling on Kimi K2.6 is 262K. One bad runaway response can cost $0.50+. 4K covers ~98% of useful answers; bump per-task as needed. Insurance policy with negligible quality cost. |
| `compression.target_ratio: 0.10` | tighter post-compression context (was 0.20) | Compressed turn is multiplied across all subsequent turns of the session. Smaller compressed context = lower per-call cost for the rest of the session. Trade-off: lossier summaries. |
| `hooks_auto_accept` | `true` | Gateway runs non-interactively; bypasses TTY consent prompt for our `pre_tool_call` hook |
| `hooks.pre_tool_call` | matcher `terminal`, command `/opt/iris-hooks/pre_tool_call.sh`, timeout 15s | Layer-1 Presidio guard for `claude` invocations |

The persona Iris embodies lives in `iris/iris-config/SOUL.md` — edit there, re-run `mint-iris-key.sh`, restart, done. Cost expectation: ~$0.005 per turn for Kimi K2.6 (the reasoning model burns ~1000-1500 reasoning tokens per response; budget `max_tokens` accordingly).

Verify the gateway started cleanly:

```bash
docker compose logs iris-gateway --tail 30
```

Expected output: `⚕ Hermes Gateway Starting...` banner, "Syncing bundled skills" with N total bundled, no tracebacks. Warnings about `No user allowlists configured` and `No messaging platforms enabled` are expected at this stage — those are Phase G concerns.

Confirm dashboard is serving:

```bash
curl -fs http://127.0.0.1:9119 -o /dev/null -w "dashboard HTTP %{http_code}\n"
```

Should print `dashboard HTTP 200`.

**STOP. Confirm with user before Phase G.**

---

## Phase G — Backups + Presidio guardrails

**Goal:** Set up nightly backups so disk failure doesn't lose data, and wire Presidio in front of LiteLLM so every Iris call gets PII protection (block financial PII, mask emails / phones, scrub leaked secrets).

### G.1 — Create `scripts/backup.sh`

Path: `~/iris/scripts/backup.sh`

```bash
#!/usr/bin/env bash
# Backs up databases and named volumes to ./backups/<date>/

set -euo pipefail

BACKUP_DIR="$(dirname "$0")/../backups/$(date +%F)"
mkdir -p "$BACKUP_DIR"

cd "$(dirname "$0")/.."

echo "Backing up to $BACKUP_DIR"

# Postgres dumps (logical, version-portable)
docker compose exec -T litellm-db pg_dump -U llmproxy litellm | gzip > "$BACKUP_DIR/litellm.sql.gz"
docker compose exec -T honcho-db pg_dump -U postgres postgres | gzip > "$BACKUP_DIR/honcho.sql.gz"

# Iris data volume (raw tar — Iris uses SQLite)
docker run --rm \
  -v iris_data:/data \
  -v "$(realpath "$BACKUP_DIR")":/backup \
  alpine tar czf /backup/iris_data.tar.gz -C /data .

# Rotate: keep last 7 days
find "$(dirname "$0")/../backups" -mindepth 1 -maxdepth 1 -type d -mtime +7 -exec rm -rf {} + 2>/dev/null || true

echo "✓ Backup complete: $BACKUP_DIR"
ls -lh "$BACKUP_DIR"
```

```bash
chmod +x ~/iris/scripts/backup.sh
```

### G.2 — Test the backup once manually

```bash
cd ~/iris
make backup
```

Should produce `~/iris/backups/<today>/` with three files. Verify sizes are non-zero.

### G.3 — Schedule the backup (platform-specific)

`scripts/backup.sh` is platform-agnostic (just runs `docker compose exec` + `docker run`). Schedule it with whatever your OS provides. Three working examples:

**Linux — cron:**
```bash
( crontab -l 2>/dev/null; echo "30 3 * * * cd $HOME/iris && bash scripts/backup.sh >> backups/backup.log 2>> backups/backup.err" ) | crontab -
```

**Linux — systemd timer** (more robust than cron, survives logout, integrated logging):
```bash
mkdir -p ~/.config/systemd/user
cat > ~/.config/systemd/user/iris-backup.service <<EOF
[Unit]
Description=Iris stack backup
[Service]
Type=oneshot
WorkingDirectory=$HOME/iris
ExecStart=/bin/bash $HOME/iris/scripts/backup.sh
EOF
cat > ~/.config/systemd/user/iris-backup.timer <<EOF
[Unit]
Description=Run iris-backup nightly at 3:30
[Timer]
OnCalendar=*-*-* 03:30:00
Persistent=true
[Install]
WantedBy=timers.target
EOF
systemctl --user daemon-reload && systemctl --user enable --now iris-backup.timer
```

**macOS — launchd:**
```bash
cat > ~/Library/LaunchAgents/com.iris.backup.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.iris.backup</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>__IRIS_HOME__/scripts/backup.sh</string>
    </array>
    <key>StartCalendarInterval</key>
    <dict><key>Hour</key><integer>3</integer><key>Minute</key><integer>30</integer></dict>
    <key>StandardOutPath</key><string>__IRIS_HOME__/backups/backup.log</string>
    <key>StandardErrorPath</key><string>__IRIS_HOME__/backups/backup.err</string>
</dict>
</plist>
EOF
# Launchd doesn't expand ~ or \$HOME inside <string> values; substitute now:
sed -i.bak "s|__IRIS_HOME__|$(cd ~/iris && pwd)|g" ~/Library/LaunchAgents/com.iris.backup.plist
rm ~/Library/LaunchAgents/com.iris.backup.plist.bak
launchctl load ~/Library/LaunchAgents/com.iris.backup.plist
launchctl list | grep iris
```

All three run `bash scripts/backup.sh` daily at 03:30. Logs go to `backups/backup.log` and `backups/backup.err`.

### G.4 — Add Presidio services to `litellm/compose.yaml`

Presidio runs as two sidecar services on the `backend` network — no host-published ports.
Append the following two services to `litellm/compose.yaml` under the existing `services:` block:

```yaml
  presidio-analyzer:
    image: mcr.microsoft.com/presidio-analyzer:latest
    container_name: presidio-analyzer
    restart: unless-stopped
    networks:
      - backend
    healthcheck:
      test: ["CMD-SHELL", "python3 -c \"import urllib.request; urllib.request.urlopen('http://localhost:3000/health')\""]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 60s

  presidio-anonymizer:
    image: mcr.microsoft.com/presidio-anonymizer:latest
    container_name: presidio-anonymizer
    restart: unless-stopped
    networks:
      - backend
    healthcheck:
      test: ["CMD-SHELL", "python3 -c \"import urllib.request; urllib.request.urlopen('http://localhost:3000/health')\""]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s
```

Wire LiteLLM to depend on both being healthy (also in `litellm/compose.yaml`):

```yaml
  litellm:
    # ... existing config ...
    depends_on:
      litellm-db:
        condition: service_healthy
      presidio-analyzer:
        condition: service_healthy
      presidio-anonymizer:
        condition: service_healthy
```

### G.5 — Add Presidio env + guardrails block

In `litellm/env.example`, add the two service URLs:

```bash
# Presidio guardrail endpoints (containers reach each other via backend network)
PRESIDIO_ANALYZER_API_BASE=http://presidio-analyzer:3000
PRESIDIO_ANONYMIZER_API_BASE=http://presidio-anonymizer:3000
```

Then in `litellm/.env`, append the same two lines (real values, not placeholders).

In `litellm/config.yaml`, add a top-level `guardrails:` block (sibling to `model_list:`, NOT nested under `litellm_settings:` — modern LiteLLM versions reject the nested format):

```yaml
guardrails:
  - guardrail_name: "presidio-pii"
    litellm_params:
      guardrail: presidio
      mode: "pre_call"
      pii_entities_config:
        # BLOCK = reject the request entirely (financial / high-risk PII)
        CREDIT_CARD: "BLOCK"
        US_SSN: "BLOCK"
        IBAN_CODE: "BLOCK"
        # MASK = replace with placeholder before sending to upstream model
        EMAIL_ADDRESS: "MASK"
        PHONE_NUMBER: "MASK"
        # PERSON / LOCATION intentionally omitted — too noisy for a personal assistant
        # where you legitimately discuss real people and places. Add them if you
        # want stricter masking and accept some false positives.

  - guardrail_name: "hide-secrets"
    litellm_params:
      guardrail: "hide-secrets"
      mode: "pre_call"
```

Apply the guardrails to every Iris virtual alias by adding a `guardrails:` field to each `iris-*` `litellm_params` block. Example for `iris-default`:

```yaml
  - model_name: iris-default
    litellm_params:
      model: openrouter/moonshotai/kimi-k2.6
      api_key: os.environ/OPENROUTER_API_KEY
      guardrails: ["presidio-pii", "hide-secrets"]
```

Repeat for `iris-cheap`, `iris-research`, `iris-coding`, `iris-marketing`, `iris-briefing`. **Skip `iris-private`** — the whole point of that route is local-only inference, where the prompt never leaves the machine; PII detection is unnecessary overhead.

### G.6 — Bring up Presidio and verify

Pull and start the two Presidio services (analyzer image is ~1.7 GB):

```bash
cd ~/iris
docker compose pull presidio-analyzer presidio-anonymizer
docker compose up -d presidio-analyzer presidio-anonymizer
```

Wait for both to become healthy (analyzer takes ~60 s on first start while it loads spaCy NLP models):

```bash
until [ "$(docker compose ps presidio-analyzer presidio-anonymizer --format '{{.Status}}' | grep -c healthy)" = "2" ]; do sleep 5; done
echo "✓ Presidio services healthy"
```

Recreate LiteLLM to load the new guardrails. **Important:** use `up -d --force-recreate`, NOT `restart`. Compose only re-reads `env_file` at container creation time — `restart` keeps the existing environment, so the new `PRESIDIO_*_API_BASE` vars from `litellm/.env` would be missing and LiteLLM crashloops with `Missing 'PRESIDIO_ANALYZER_API_BASE' from environment`:

```bash
docker compose up -d litellm --force-recreate
docker compose logs litellm --tail 30
```

Confirm the env vars are visible inside the new container:

```bash
docker compose exec -T litellm env | grep ^PRESIDIO
# Expect: PRESIDIO_ANALYZER_API_BASE=http://presidio-analyzer:3000
#         PRESIDIO_ANONYMIZER_API_BASE=http://presidio-anonymizer:3000
```

Look for guardrail-load messages and **no tracebacks**. The exact log string varies by LiteLLM version, but you should see `presidio` and `hide-secrets` mentioned.

**Smoke test: BLOCK on credit card.** Visa's published test number `4111-1111-1111-1111` is recognized by Presidio's `CREDIT_CARD` recognizer:

```bash
IRIS_VKEY=$(grep IRIS_VIRTUAL_KEY ~/iris/.env | cut -d= -f2)
curl -s -X POST http://127.0.0.1:4000/v1/chat/completions \
  -H "Authorization: Bearer $IRIS_VKEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "iris-default",
    "messages": [{"role": "user", "content": "My card is 4111-1111-1111-1111"}],
    "max_tokens": 50
  }' | jq
```

Expected: a 400 / guardrail-block response mentioning `CREDIT_CARD`. If the request succeeds and reaches the model, Presidio is not actually wired up — re-check that the `guardrails:` field is set on each `iris-*` alias.

**Smoke test: MASK on email.** Email addresses should be replaced with `<EMAIL_ADDRESS>` before reaching the upstream model:

```bash
curl -s -X POST http://127.0.0.1:4000/v1/chat/completions \
  -H "Authorization: Bearer $IRIS_VKEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "iris-default",
    "messages": [{"role": "user", "content": "Email user@example.com — what PII type did I just mention?"}],
    "max_tokens": 200
  }' | jq -r '.choices[0].message.content'
```

Expected: the model says it saw an `<EMAIL_ADDRESS>` placeholder, NOT the literal `user@example.com`. Confirms masking flows through to the upstream LLM.

### G.7 — Set up shared workspace + claude-cli container

**Goal:** Add a dedicated `claude-cli` container running Claude Code CLI, with credentials persisted in a Docker volume and a host workspace bind-mounted into both iris-gateway and claude-cli at `/workspace`.

**Why this design:**
- Hermes' main brain stays on Kimi K2.6 via LiteLLM (cheap, audited, guardrailed)
- When Hermes' built-in `claude-code` skill or upstream `/cc` command delegates a task, that subprocess runs against your Claude Max plan (no extra API billing)
- Both containers see the same `/workspace` view, so files written by Hermes are immediately readable by Claude Code, and vice versa
- Three Presidio hook layers (G.10, G.11) enforce PII masking on every Anthropic-bound prompt and on file content Claude Code reads

Create the workspace dir on the host:

```bash
mkdir -p ~/iris-workspace
```

This is the **only** host directory the agent reads/writes by default. Treat it like a public folder — don't put `.env`, SSH keys, finance docs, or secrets there. For ad-hoc work on existing repos, add a one-off mount in `compose.override.yaml` (gitignored).

**Reproducibility design:** the container's iris-flavoured Claude Code config (CLAUDE.md, rules/, agents/, skills/, settings.json with security hooks pre-wired) lives as source files in `claude-cli/iris-config/` and is baked into the image. An entrypoint script seeds these into the credential volume on first start and symlinks Claude Code's runtime state file into the volume so OAuth tokens survive recreates. Means: `docker compose up -d --force-recreate` reproduces the container completely from build artifacts; only `docker volume rm` loses state.

**If you cloned this repo:** the `claude-cli/iris-config/` directory is already populated with a sensible default config (CLAUDE.md, topical rules, custom subagents, skills, settings.json with security hooks + 10 enabled plugins from `pm-skills` and `claude-plugins-official` marketplaces, 71 skill overrides set to `name-only` for context efficiency). Skip ahead to the build step.

**If you're setting up from scratch and want to seed from your own host config:** snapshot ONCE at install. Container and host evolve independently afterwards.

```bash
mkdir -p ~/iris/claude-cli/iris-config
cp ~/.claude/CLAUDE.md ~/iris/claude-cli/iris-config/
cp -R ~/.claude/rules ~/.claude/agents ~/.claude/skills ~/iris/claude-cli/iris-config/
```

Then **scrub anything sensitive before committing** (these patterns are common host-tied references):
```bash
cd ~/iris/claude-cli/iris-config
grep -rE '[a-zA-Z0-9._-]+@[a-zA-Z0-9.-]+\.[a-z]{2,}' .   # emails
grep -rE '/Users/[a-zA-Z0-9_.-]+'                          # absolute home paths
grep -rE '\b(your-internal-project-name|your-org)\b' .     # internal names
```
Audit the matches; replace user-specific references with placeholders or remove the sections. The version of `iris-config/` checked into THIS repo has been pre-scrubbed of all such references — internal project names replaced with generic descriptions, no host paths, no emails.

For settings.json, a curated default is committed. If you want to also import from your own host:
```bash
python3 - <<'PYEOF'
import json
host = json.loads(open("~/.claude/settings.json").read())
container = json.loads(open("~/iris/claude-cli/iris-config/settings.json").read())
# Take only safe fields; preserve container's hooks (security guards) and theme
for k in ["enabledPlugins", "extraKnownMarketplaces", "skillOverrides", "skillListingMaxDescChars"]:
    if k in host: container[k] = host[k]
# permissions: take allow list from host, keep container's deny list (which uses container paths)
if "permissions" in host:
    container["permissions"]["allow"] = host["permissions"].get("allow", [])
open("~/iris/claude-cli/iris-config/settings.json", "w").write(json.dumps(container, indent=2) + "\n")
print("✓ merged safe fields from host settings")
PYEOF
```

**Explicitly NOT brought across (and intentionally not installed in container):**
- `~/.claude/hooks/skill-defense/*` — paths assume host `$HOME` and rely on host `brew`-installed tools; container has its own security model (read-deny / write-secret / pii-context guards in G.11)
- `~/.claude/plugins/*` — `installed_plugins.json` references absolute host paths that won't resolve in the container; re-install via `/plugin install <name>` inside the container if wanted
- `~/.claude/sessions/`, `history.jsonl`, `paste-cache/` — sensitive runtime / transcript data
- **MemPalace** (`mempalace` CLI + MCP server + `~/.mempalace/` storage) — the stack already has Honcho (pgvector + redis) for semantic memory at the Iris layer. Claude Code subprocesses are short-lived per-task and don't need their own persistent memory; running both would duplicate Honcho's role and risk cross-container concurrent-write corruption of the Chroma DB. MemPalace stays a host-only tool.

Then create `claude-cli/iris-config/settings.json` with the container-specific security hooks pre-wired (Presidio prompt-block + read-deny + write-secret-guard + pii-context-injector). Full content is in the live file at `claude-cli/iris-config/settings.json` — see G.11 below for the JSON shape.

Create `claude-cli/Dockerfile`:

```dockerfile
FROM node:22-slim

# Claude Code CLI + Python (for presidio-mask helper used by hooks)
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 python3-requests ca-certificates \
  && rm -rf /var/lib/apt/lists/*
RUN npm install -g @anthropic-ai/claude-code

# Run as non-root; UID/GID align with host user via build args.
# Reuse existing group at HERMES_GID if one already exists (e.g. dialout=20 on Debian).
ARG HERMES_UID=10000
ARG HERMES_GID=10000
RUN (getent group ${HERMES_GID} >/dev/null || groupadd -g ${HERMES_GID} claude) && \
    useradd -m -u ${HERMES_UID} -g ${HERMES_GID} -s /bin/bash claude

# Pre-create the credential dir owned by claude so the OAuth volume mount inherits.
RUN mkdir -p /home/claude/.claude && chown -R claude /home/claude/.claude

# Iris defaults + entrypoint that seeds them on first start (idempotent)
COPY --chown=claude:claude iris-config /home/claude/.claude-defaults
COPY --chown=claude:claude entrypoint.sh /usr/local/bin/iris-init
RUN chmod +x /usr/local/bin/iris-init

# Hook scripts — see G.9 / G.11 for the source of each
COPY --chown=claude:claude presidio-mask.py /usr/local/bin/presidio-mask
COPY --chown=claude:claude presidio-mask-prompt.sh /usr/local/bin/presidio-mask-prompt
COPY --chown=claude:claude read-deny-guard.sh /usr/local/bin/read-deny-guard
COPY --chown=claude:claude write-secret-guard.sh /usr/local/bin/write-secret-guard
COPY --chown=claude:claude pii-context-injector.sh /usr/local/bin/pii-context-injector
RUN chmod +x \
    /usr/local/bin/presidio-mask \
    /usr/local/bin/presidio-mask-prompt \
    /usr/local/bin/read-deny-guard \
    /usr/local/bin/write-secret-guard \
    /usr/local/bin/pii-context-injector

USER claude
WORKDIR /workspace

ENTRYPOINT ["/usr/local/bin/iris-init"]
CMD ["tail", "-f", "/dev/null"]
```

Create `claude-cli/entrypoint.sh`:

```bash
#!/usr/bin/env bash
# Container init for claude-cli — runs as `claude` user. Idempotent.
#  1. Seed /home/claude/.claude/ from baked-in iris-defaults if missing/empty
#  2. Symlink /home/claude/.claude.json into the persistent volume
set -euo pipefail

DEFAULTS_DIR="/home/claude/.claude-defaults"
LIVE_DIR="/home/claude/.claude"
RUNTIME_FILE="/home/claude/.claude.json"
RUNTIME_IN_VOLUME="$LIVE_DIR/runtime.json"

mkdir -p "$LIVE_DIR"

for src in "$DEFAULTS_DIR"/*; do
  name=$(basename "$src")
  dest="$LIVE_DIR/$name"
  if [ ! -e "$dest" ]; then
    cp -R "$src" "$dest"
    echo "iris-init: seeded $dest (was missing)"
  elif [ -d "$src" ] && [ -d "$dest" ] && [ -z "$(ls -A "$dest" 2>/dev/null)" ]; then
    cp -R "$src/." "$dest/"
    echo "iris-init: seeded $dest (was empty dir)"
  elif [ -f "$src" ] && [ -f "$dest" ] && [ ! -s "$dest" ]; then
    cp "$src" "$dest"
    echo "iris-init: seeded $dest (was empty file)"
  fi
done

# Symlink runtime.json into the volume so OAuth state survives recreates
if [ ! -L "$RUNTIME_FILE" ] && [ ! -e "$RUNTIME_FILE" ]; then
  ln -s "$RUNTIME_IN_VOLUME" "$RUNTIME_FILE"
  echo "iris-init: linked $RUNTIME_FILE -> $RUNTIME_IN_VOLUME"
elif [ -f "$RUNTIME_FILE" ] && [ ! -L "$RUNTIME_FILE" ]; then
  mv "$RUNTIME_FILE" "$RUNTIME_IN_VOLUME"
  ln -s "$RUNTIME_IN_VOLUME" "$RUNTIME_FILE"
  echo "iris-init: migrated $RUNTIME_FILE -> $RUNTIME_IN_VOLUME"
fi

exec "$@"
```

Create `claude-cli/compose.yaml`:

```yaml
volumes:
  claude_creds:
  iris_workspace_data:

services:
  claude-cli:
    build:
      context: .
      args:
        HERMES_UID: ${HERMES_UID:-10000}
        HERMES_GID: ${HERMES_GID:-10000}
    image: claude-cli:local
    container_name: claude-cli
    restart: unless-stopped
    # No `user:` directive — Dockerfile USER claude handles it; entrypoint
    # already runs as claude (matches the OAuth + volume ownership model).
    working_dir: /workspace
    volumes:
      - claude_creds:/home/claude/.claude
      - ${HOME}/iris-workspace:/workspace
    environment:
      PRESIDIO_ANALYZER_API_BASE: http://presidio-analyzer:3000
      PRESIDIO_ANONYMIZER_API_BASE: http://presidio-anonymizer:3000
    networks:
      - frontend  # for Anthropic API egress
      - backend   # for Presidio access from hook scripts
    # Long-running keepalive; commands fired via `docker exec` from iris-gateway
    command: ["tail", "-f", "/dev/null"]
```

Add the new compose subdirectory to top-level `compose.yaml`:

```yaml
include:
  - ./iris/compose.yaml
  - ./litellm/compose.yaml
  - ./honcho/compose.yaml
  - ./claude-cli/compose.yaml   # new
```

Update `iris/compose.yaml` so iris-gateway can:
1. Reach the Docker socket (to `docker exec` into claude-cli)
2. See the same `/workspace` as claude-cli
3. Reach Presidio for hook-based masking

Add to `iris-gateway` (and `iris-dashboard` for symmetry):

```yaml
    volumes:
      - iris_data:/opt/data
      - ${HOME}/iris-workspace:/workspace        # shared with claude-cli
      - /var/run/docker.sock:/var/run/docker.sock:ro   # iris-gateway only
```

The dashboard typically doesn't need the docker.sock — only iris-gateway does. Add the workspace mount to both, but the docker.sock only to iris-gateway.

Also add `frontend` to iris-gateway's networks (it currently has only `backend`) so it can resolve `presidio-anonymizer`. Verify via:

```yaml
    networks:
      - frontend
      - backend
```

Build, start, and verify:

```bash
cd ~/iris
docker compose build claude-cli
docker compose up -d claude-cli
docker compose ps claude-cli
docker compose exec -T claude-cli claude --version
```

Expected: a `claude` version string, no auth (we OAuth in G.8).

### G.8 — Claude Max plan OAuth (one-time, interactive)

**About reproducibility (read first):** the claude-cli container is designed to be fully reproducible from build artifacts. Snapshot of your iris config (CLAUDE.md, rules/, agents/, skills/, settings.json with security hooks pre-wired) lives in `claude-cli/iris-config/` in the source tree and is baked into the image at build time. An entrypoint script (`claude-cli/entrypoint.sh`) seeds these into the credential volume on first start and symlinks `/home/claude/.claude.json` (Claude Code's runtime state) into the volume — so OAuth tokens, .claude.json, and config all survive container recreates and rebuilds.

**Pre-step:** ensure the credentials volume is writable by `claude`. Docker creates named volumes as root-owned. Without this, `claude /login` silently fails to persist tokens:

```bash
docker compose exec -T --user root claude-cli chown -R claude /home/claude/.claude
```

(Only needed if you've manually mucked with the volume; on a fresh install the Dockerfile pre-creates the dir as `claude`-owned and the volume inherits.)

Now run the OAuth flow:

```bash
docker exec -it claude-cli claude
```

Claude Code prints an OAuth URL and waits. Open the URL in your host browser, log in with your Claude Max account, paste the auth code back into the terminal. The token is written to `/home/claude/.claude/` which is the `claude_creds` named volume — survives container restarts.

After login, validate:

```bash
docker exec -T claude-cli claude --print "Say only the word: ready" --output-format text
```

Expected: a single token "ready" (or close to it), confirming the OAuth flow successfully authorized API access via your Max plan.

**One-time post-OAuth fixup** — Claude Code initially writes its runtime state to `/home/claude/.claude.json` (a path OUTSIDE the credential volume, so it'd be lost on container recreate). The entrypoint creates a symlink to `/home/claude/.claude/runtime.json` on every start, but on the FIRST start (right after OAuth), the actual file is at `/home/claude/.claude.json` — not yet at the symlink target. Move it once:

```bash
docker compose exec -T claude-cli /bin/bash -c '
if [ -f /home/claude/.claude.json ] && [ ! -L /home/claude/.claude.json ]; then
  mv /home/claude/.claude.json /home/claude/.claude/runtime.json
  ln -s /home/claude/.claude/runtime.json /home/claude/.claude.json
  echo "✓ migrated runtime.json into volume"
fi'
```

After this, OAuth state survives `docker compose up -d --force-recreate` and `docker compose down` + `docker compose up -d`. (You'd only lose it if you `docker volume rm iris_claude_creds` — which is a destructive op anyway.)

### G.9 — `presidio-mask` helper (used by all three hook layers)

Single Python script that wraps Presidio's analyzer + anonymizer REST APIs. Reads JSON from stdin, writes masked JSON to stdout, exits non-zero on a BLOCK match.

Create `claude-cli/presidio-mask.py`:

```python
#!/usr/bin/env python3
"""Presidio-backed PII masker for Hermes/Claude-Code hooks.

stdin:  {"text": "...", "mode": "mask" | "block-on-match"}
stdout: {"text": "...masked..."}    on success
exit:   0 = ok (masked or no PII found)
        1 = BLOCK entity matched and mode == "block-on-match"
        2 = Presidio unreachable / config error
"""
import json
import os
import sys
import requests

ANALYZER = os.environ.get("PRESIDIO_ANALYZER_API_BASE", "http://presidio-analyzer:3000")
ANONYMIZER = os.environ.get("PRESIDIO_ANONYMIZER_API_BASE", "http://presidio-anonymizer:3000")

BLOCK_ENTITIES = {"CREDIT_CARD", "US_SSN", "IBAN_CODE"}
MASK_ENTITIES = {"EMAIL_ADDRESS", "PHONE_NUMBER"}
ALL_ENTITIES = sorted(BLOCK_ENTITIES | MASK_ENTITIES)

def main() -> int:
    payload = json.load(sys.stdin)
    text = payload.get("text", "")
    mode = payload.get("mode", "mask")
    if not text:
        json.dump({"text": text}, sys.stdout)
        return 0

    try:
        spans = requests.post(
            f"{ANALYZER}/analyze",
            json={"text": text, "language": "en", "entities": ALL_ENTITIES},
            timeout=10,
        ).json()
    except Exception as e:
        sys.stderr.write(f"presidio-mask: analyzer unreachable: {e}\n")
        return 2

    if mode == "block-on-match":
        for s in spans:
            if s.get("entity_type") in BLOCK_ENTITIES:
                sys.stderr.write(
                    f"presidio-mask: BLOCK on {s['entity_type']} (start={s['start']}, end={s['end']})\n"
                )
                return 1

    try:
        result = requests.post(
            f"{ANONYMIZER}/anonymize",
            json={
                "text": text,
                "analyzer_results": spans,
                "anonymizers": {
                    e: {"type": "replace", "new_value": f"<{e}>"} for e in ALL_ENTITIES
                },
            },
            timeout=10,
        ).json()
    except Exception as e:
        sys.stderr.write(f"presidio-mask: anonymizer unreachable: {e}\n")
        return 2

    json.dump({"text": result.get("text", text)}, sys.stdout)
    return 0

if __name__ == "__main__":
    sys.exit(main())
```

Bake the same file into iris-gateway too (Layer 1 hook needs it). Save it as `iris/presidio-mask.py` (identical content) and ensure both Dockerfiles install Python+requests + drop it at `/usr/local/bin/presidio-mask` (executable).

Update `claude-cli/Dockerfile` to install the helper:

```dockerfile
COPY --chown=claude:claude presidio-mask.py /usr/local/bin/presidio-mask
RUN chmod +x /usr/local/bin/presidio-mask
```

For iris-gateway, the `iris:local` upstream image is built from a clone we don't control. Create a thin extending Dockerfile `iris/Dockerfile.iris-bridge`:

```dockerfile
FROM iris:local

USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
      python3-requests docker.io ca-certificates \
  && rm -rf /var/lib/apt/lists/*

COPY presidio-mask.py /usr/local/bin/presidio-mask
COPY claude-wrapper.sh /usr/local/bin/claude
COPY hooks/pre_tool_call.sh /opt/iris-hooks/pre_tool_call.sh
RUN chmod +x /usr/local/bin/presidio-mask /usr/local/bin/claude /opt/iris-hooks/pre_tool_call.sh

USER hermes
```

In `iris/compose.yaml`, swap iris-gateway / iris-dashboard's `build:` to use this:

```yaml
  iris-gateway:
    build:
      context: .
      dockerfile: Dockerfile.iris-bridge
    image: iris-bridge:local
    # ... rest unchanged ...
```

(`iris-dashboard` doesn't need the bridge — keep it on `iris:local`.)

### G.10 — Layer 1: claude wrapper + Hermes `pre_tool_call` hook

Create `iris/claude-wrapper.sh`:

```bash
#!/usr/bin/env bash
# claude wrapper inside iris-gateway. Forwards to claude-cli container,
# preserving working directory and stdin/stdout streams.
set -euo pipefail

# Translate iris-gateway's /workspace path → claude-cli's /workspace (same path)
WORKDIR_REL=""
case "$PWD" in
  /workspace*) WORKDIR_REL="$PWD" ;;
  *)           WORKDIR_REL="/workspace" ;;  # fallback
esac

exec docker exec -i -w "$WORKDIR_REL" -u "$(id -u):$(id -g)" claude-cli claude "$@"
```

Create `iris/hooks/pre_tool_call.sh`:

```bash
#!/usr/bin/env bash
# Hermes pre_tool_call hook — Layer 1 PII gate for terminal commands that
# invoke `claude`. Reads Hermes hook payload (JSON) from stdin.
#
# If tool != terminal or command doesn't start with `claude`, pass through.
# Otherwise extract the prompt arg, mask via Presidio (block-on-match), and
# rewrite the command. On BLOCK, exit 1 to veto the tool call.
set -euo pipefail

PAYLOAD=$(cat)
TOOL=$(echo "$PAYLOAD" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("tool",""))')
CMD=$(echo "$PAYLOAD" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("args",{}).get("command",""))')

# Pass-through for non-terminal tools or non-claude commands
case "$TOOL:$CMD" in
  terminal:claude*) ;;
  *) echo "$PAYLOAD"; exit 0 ;;
esac

# Extract prompt arg (-p '...' or --print '...')
PROMPT=$(python3 -c '
import shlex, sys
toks = shlex.split(sys.argv[1])
for i, t in enumerate(toks):
    if t in ("-p", "--print") and i + 1 < len(toks):
        print(toks[i+1])
        break
' "$CMD")

if [ -z "$PROMPT" ]; then
  # Interactive mode (no -p) — pass through unchanged
  echo "$PAYLOAD"; exit 0
fi

# Mask via Presidio (block on CC/SSN/IBAN matches)
MASKED_JSON=$(printf '%s' "$PROMPT" | python3 -c '
import json, sys
print(json.dumps({"text": sys.stdin.read(), "mode": "block-on-match"}))
' | /usr/local/bin/presidio-mask)
RC=$?

if [ $RC -eq 1 ]; then
  echo "{\"veto\": true, \"reason\": \"Layer-1 Presidio BLOCK on prompt\"}" >&2
  exit 1
fi
if [ $RC -ne 0 ]; then
  echo "presidio-mask returned $RC; passing through unredacted" >&2
  echo "$PAYLOAD"; exit 0
fi

MASKED_PROMPT=$(echo "$MASKED_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["text"])')

# Rewrite command with masked prompt (preserves all other args)
NEW_CMD=$(python3 -c '
import shlex, sys
orig = shlex.split(sys.argv[1])
masked = sys.argv[2]
out = []
i = 0
while i < len(orig):
    if orig[i] in ("-p", "--print") and i + 1 < len(orig):
        out.append(orig[i]); out.append(masked); i += 2
    else:
        out.append(orig[i]); i += 1
print(shlex.join(out))
' "$CMD" "$MASKED_PROMPT")

# Emit modified payload — Hermes uses this rewritten command
echo "$PAYLOAD" | python3 -c '
import json, sys
d = json.load(sys.stdin)
d["args"]["command"] = sys.argv[1]
print(json.dumps(d))
' "$NEW_CMD"
```

Wire the hook into Hermes by appending to `/opt/data/config.yaml`:

```yaml
hooks:
  pre_tool_call:
    script: /opt/iris-hooks/pre_tool_call.sh
    timeout_seconds: 15
```

Restart iris-gateway after rebuilding the image:

```bash
docker compose build iris-gateway
docker compose up -d iris-gateway --force-recreate
```

### G.11 — Layers 2 & 3: Claude Code's own hooks (corrected after API reality check)

**Important reality check:** Claude Code's hook API is more limited than community blog posts suggest:

| Hook | What it can do | What it CANNOT do |
|---|---|---|
| `UserPromptSubmit` | `decision: "block"` the prompt; add `additionalContext` | Modify the prompt text — Claude Code always sends the user's literal prompt to Anthropic |
| `PreToolUse` | `permissionDecision: "deny"` the tool call; modify `tool_input` via `updatedInput` | — |
| `PostToolUse` | Add `additionalContext` so Claude is informed | Modify `tool_response` — the literal output is already in Claude's context |

This means **content-level masking is impossible via the public hook API**. The community workaround is filename-based blocking + write-side secret scanning + read-side awareness injection. (Anthropic's own `deny` rules in `settings.json` are documented as buggy — issues [#24846](https://github.com/anthropics/claude-code/issues/24846) and [#6699](https://github.com/anthropics/claude-code/issues/6699). Hooks are the reliable enforcement.)

Four hook scripts, all dropped into `claude-cli/` and baked into the Dockerfile:

- **`presidio-mask-prompt.sh`** (UserPromptSubmit) — BLOCKs prompts containing CC / SSN / IBAN. Cannot mask other PII (Claude Code API limit).
- **`read-deny-guard.sh`** (PreToolUse on `Read` + `Bash`) — Hard-blocks reads of files matching sensitive name patterns: `*.env`, `.env.*`, `*.pem`, `*.key`, `*credentials*`, `*secret*`, `*.token`, `id_rsa*`, `.ssh/*`, `.aws/credentials*`, `.netrc`, etc. For Bash, blocks `cat/grep/head/tail/...` of those paths.
- **`write-secret-guard.sh`** (PreToolUse on `Edit` + `Write` + `Bash`) — Blocks writes whose new content matches API-key regexes (AWS, GitHub, Stripe, Anthropic, Google, Slack, OpenRouter, Postgres/Mongo URIs with creds, PEM private keys).
- **`pii-context-injector.sh`** (PostToolUse on `Read` + `Bash`) — Runs Presidio on the tool result. If PII is detected, injects an `additionalContext` warning telling Claude to refer to entities as `<REDACTED>` rather than echo them. Best-effort defense; Claude can be re-prompted around it.

Each script is self-contained Python (no bash/jq plumbing). See live files in `claude-cli/` for the full content — they're too long to inline here but are version-controlled and editable.

Wire them all together in `claude-cli/settings.json`:

```json
{
  "hooks": {
    "UserPromptSubmit": [
      {"hooks": [{"type": "command", "command": "/usr/local/bin/presidio-mask-prompt"}]}
    ],
    "PreToolUse": [
      {"matcher": "Read|Bash",
       "hooks": [{"type": "command", "command": "/usr/local/bin/read-deny-guard"}]},
      {"matcher": "Edit|Write|Bash",
       "hooks": [{"type": "command", "command": "/usr/local/bin/write-secret-guard"}]}
    ],
    "PostToolUse": [
      {"matcher": "Read|Bash",
       "hooks": [{"type": "command", "command": "/usr/local/bin/pii-context-injector"}]}
    ]
  }
}
```

Update the Dockerfile to bake all four scripts:

```dockerfile
COPY --chown=claude:claude presidio-mask.py /usr/local/bin/presidio-mask
COPY --chown=claude:claude presidio-mask-prompt.sh /usr/local/bin/presidio-mask-prompt
COPY --chown=claude:claude read-deny-guard.sh /usr/local/bin/read-deny-guard
COPY --chown=claude:claude write-secret-guard.sh /usr/local/bin/write-secret-guard
COPY --chown=claude:claude pii-context-injector.sh /usr/local/bin/pii-context-injector
RUN chmod +x \
    /usr/local/bin/presidio-mask \
    /usr/local/bin/presidio-mask-prompt \
    /usr/local/bin/read-deny-guard \
    /usr/local/bin/write-secret-guard \
    /usr/local/bin/pii-context-injector
```

After OAuth (G.8), Claude Code wrote a default `settings.json` at `/home/claude/.claude/settings.json`. Merge our `hooks` block into it (don't overwrite — preserves theme + future Claude Code settings). Inside the container:

```bash
docker compose exec -T claude-cli python3 -c '
import json
p = "/home/claude/.claude/settings.json"
data = json.load(open(p))
data["hooks"] = {
    "UserPromptSubmit": [{"hooks": [{"type": "command", "command": "/usr/local/bin/presidio-mask-prompt"}]}],
    "PreToolUse": [
        {"matcher": "Read|Bash",
         "hooks": [{"type": "command", "command": "/usr/local/bin/read-deny-guard"}]},
        {"matcher": "Edit|Write|Bash",
         "hooks": [{"type": "command", "command": "/usr/local/bin/write-secret-guard"}]}
    ],
    "PostToolUse": [{"matcher": "Read|Bash",
                     "hooks": [{"type": "command", "command": "/usr/local/bin/pii-context-injector"}]}]
}
json.dump(data, open(p, "w"), indent=2)
print("✓ hooks merged into settings.json")'
```

Rebuild + restart:

```bash
docker compose build claude-cli
docker compose up -d claude-cli --force-recreate
```

### G.12 — Smoke tests (all three layers)

**Layer 1 — Hermes hook BLOCKs CC in claude command:**

```bash
docker compose exec -T iris-gateway sh -c '
echo "{\"tool\":\"terminal\",\"args\":{\"command\":\"claude -p \\\"my card 4111-1111-1111-1111\\\"\"}}" | /opt/iris-hooks/pre_tool_call.sh
echo "exit: $?"
'
```

Expected: exit 1, stderr mentions BLOCK on prompt.

**Layer 1 — Hermes hook MASKs email in claude command:**

```bash
docker compose exec -T iris-gateway sh -c '
echo "{\"tool\":\"terminal\",\"args\":{\"command\":\"claude -p \\\"email user@example.com\\\"\"}}" | /opt/iris-hooks/pre_tool_call.sh
'
```

Expected: stdout JSON with `command` containing `<EMAIL_ADDRESS>` instead of `user@example.com`.

**Layer 2 — UserPromptSubmit blocks credit card prompts:**

```bash
docker compose exec -T claude-cli claude --print "my card 4111-1111-1111-1111" --output-format text
```

Expected: empty stdout (the request was blocked at the hook before Anthropic was called). Confirm via `--include-hook-events --verbose --output-format stream-json` if you want to see the `decision: "block"` JSON.

**Layer 3a — read-deny-guard refuses sensitive paths:**

```bash
echo 'secret_password=hunter2' > ~/iris-workspace/.env
docker compose exec -T claude-cli claude --print "Read /workspace/.env and tell me what's in it" --output-format text
```

Expected: Claude reports being blocked, mentions the `*.env` pattern match, and refuses to retry.

**Layer 3b — write-secret-guard blocks AWS-key writes:**

```bash
docker compose exec -T claude-cli claude --print "Write a Python file at /workspace/leak.py containing the line: api_key = \"AKIAIOSFODNN7EXAMPLE\"" --output-format text
```

Expected: Claude reports being blocked on the `AWS access key` pattern; no file written. Verify: `[ ! -f ~/iris-workspace/leak.py ] && echo "✓ blocked"`.

**Layer 3c — pii-context-injector warns Claude about emails in file content:**

```bash
echo "Contact alice@example.com about the meeting" > ~/iris-workspace/note.txt
docker compose exec -T claude-cli claude --print "Read /workspace/note.txt and tell me ONLY who I should contact (name only, no email)" --output-format text
```

Expected: Claude returns just `Alice` (or similar), having heeded the additionalContext warning to refer to PII as `<REDACTED>` rather than echo the literal email.

**Honest scope of guarantees:**
- ✅ Hard-blocked: prompts containing CC/SSN/IBAN; reads of files matching `*.env`/`*.pem`/`*credentials*`; writes containing well-known API-key patterns.
- 🟡 Best-effort: Claude refraining from echoing PII in file content it read (additionalContext is a polite request, not a guarantee — Claude may comply but isn't forced to).
- ❌ Out of scope: masking arbitrary file content before it reaches Anthropic (Claude Code API doesn't permit this). For genuinely sensitive data, route through `iris-private` (local Ollama, never leaves machine).

**STOP. Confirm with user before Phase H.**

---

## Phase H — Final verification and cleanup

### H.1 — Full health check

```bash
cd ~/iris
docker compose ps
make config > /dev/null && echo "✓ dev config OK"
make config-prod > /dev/null && echo "✓ prod config OK"
```

### H.2 — Commit to git

```bash
cd ~/iris
git add .
git status        # verify .env files are NOT staged
git commit -m "Initial agent stack — Iris + LiteLLM + Honcho + Prometheus"
```

If `.env` shows up in `git status`, STOP — `.gitignore` isn't working. Fix before commit.

### H.3 — Document virtual keys for the user

Create `~/iris/.docs/virtual-keys.md` with key aliases and what they're for. Don't include the actual key values — those live in `.env` and the LiteLLM admin UI at `http://127.0.0.1:4000/ui`.

### H.4 — Hand back to user

Tell the user:

- Stack is up at:
  - Iris dashboard: http://127.0.0.1:9119
  - LiteLLM admin: http://127.0.0.1:4000/ui (use master key from `litellm/.env`)
  - Prometheus: http://127.0.0.1:9090
- To stop: `make down`
- To restart: `make dev`
- Backup runs nightly at 3:30 AM; manual backup via `make backup`
- For prod hardening (when deploying): `make prod` instead of `make dev`

**Done.**

---

## Failure recovery

If something breaks irreparably during install:

```bash
cd ~/iris
docker compose down -v   # nuke volumes (DESTRUCTIVE)
docker compose rm -f
docker images | grep -E '(iris|honcho)' | awk '{print $3}' | xargs docker rmi -f
git clean -fdx           # remove untracked files
git reset --hard         # reset tracked files
```

Then restart from Phase A. The cloned upstream repos (`hermes-agent/`, `honcho-src/`) survive `git clean -fdx` if listed in `.gitignore`.

---

## Notes for Claude Code

- This file is the source of truth. If something here conflicts with general best practices, follow this file unless it would clearly break something — then stop and ask.
- Show files before writing them. The user reads carefully.
- Don't echo API keys or passwords back to the user after they've been provided.
- Use `docker compose` (v2 syntax), not `docker-compose` (v1).
- Mac-specific: `sed -i.bak` works on both Mac and Linux. Don't use GNU-only sed flags.
- After completing all phases, the user may want help with: writing skills, configuring channels (Telegram), or adding cron jobs. Those are out of scope for this install — finish the install cleanly, then offer.
