# Iris V2 — Install & Architecture Guide

> **Status (2026-05-04):** Phases 1-4 + 6 are SHIPPED on `main`. Phases 5 and 7 are documented but their full implementation is operator-dependent (sandbox runtime choice, OIDC/Vault provisioning) — see [PHASE_5_SANDBOX.md](PHASE_5_SANDBOX.md) and [PHASE_7_TENANCY.md](PHASE_7_TENANCY.md) for the decision trees. Mission Control is provided via three Grafana dashboards (fleet overview, agent detail, compliance & audit) instead of a separate UI.

| Phase | Scope | Status |
|---|---|---|
| 1 | Observability (OTel + Loki + Grafana + Prom) | SHIPPED |
| 2 | Self-learning loop (lessons memory + Hermes Curator + nudges) | SHIPPED |
| 3 | Event log + iris-curator (intent/observation split) | SHIPPED |
| 4 | Multi-profile fleet (persona, researcher, coder, ops) | SHIPPED |
| 5 | Sandbox dispatch | DOC — operator picks runtime |
| 6 | Audit log Postgres + Grafana compliance dashboards | SHIPPED |
| 7 | Multi-tenant (OIDC, RBAC, Vault, pgvector namespacing) | DOC — corporate-only |

Read top-to-bottom on the first pass; come back to specific phases when implementing.

V1 (current `main`) treated git as the substrate for every learned action — every package install, every cron schedule, every MCP server became a branch + commit + human review. That worked while the agent was passive. Once Iris started exercising her capabilities autonomously, the GitHub flow collapsed under its own friction: 20 branches a day, 5+ wrapper bugs from `set -e` + bash + git stash interactions, 40-minute autonomous runs with no failure memory. V2 splits the architecture into five planes that each address a specific failure mode of V1, and unifies every existing component under a single observability layer.

---

## 0. Why V2

| V1 limitation observed | V2 fix |
|---|---|
| 1. 40-min autonomous runs because Iris had no skill catalog cache | Plane 3 promotes Hermes's lazy skill catalog + adds catalog injection for our manifests at startup |
| 2. ~6 wrapper bugs/day from bash + interactive prompts | Wrappers move to small Python orchestrators; sandbox dispatch isolates failures |
| 3. 4 separate reconcile scripts, all with the same shape | Single reconciler controller with pluggable handlers |
| 4. 3 manifest formats (txt/yaml/json) | Standardize on YAML where possible; JSON only where Hermes natively requires it (skills snapshot) |
| 5. 20 iris-self/* branches per day | Event log + Curator batch PRs — one PR per cadence, not per action |
| 6. `down -v` wipes OAuth, virtual keys, Hermes state | Event log + secrets bind-mount survive volume wipe |
| 7. No introspection — health requires checking 5 places | Plane 1 (observability) is the single source of truth for "what is happening now" |
| 8. No multi-user / multi-agent story | Plane 2 (fleet orchestration) — Hermes profiles + MCP serve mode + Kanban |
| 9. Hermes Curator, periodic nudge, Honcho dialectic, Kanban, MCP serve, sessions FTS5 — all unused | Plane 3 utilizes every Hermes layer that addresses a V1 bottleneck |

V2 is **purely additive** — every V1 container stays. LiteLLM, Presidio, Honcho, Prometheus, claude-cli, iris-gateway, iris-dashboard, the three Docker networks, and all five Presidio guardrail layers carry forward unchanged. V2 adds cross-cutting planes (observability, fleet, governance, sandbox dispatch) that V1 was missing.

---

## 1. The 5 planes

```
PLANE 1 — OBSERVABILITY (cuts through everything below)
  OpenTelemetry traces • Prometheus metrics • Loki logs • Grafana
  Mission Control fleet UI • Audit log (immutable, queryable)
                            |
                            v
PLANE 2 — FLEET ORCHESTRATION (multi-agent)
  N profiles (persona, researcher, coder, ops, ...)
  MCP serve mode for cross-agent RPC
  Kanban for async cross-agent task coordination
  Honcho per-peer cards (per-user identity)
                            |
                            v
PLANE 3 — HERMES NATIVE LAYERS (use all of them)
  Skills 3-tier  | Curator         | Periodic nudge | Subagent delegation
  Honcho memory  | Sessions FTS5   | Kanban         | Plugins
  MCP servers    | MCP serve mode  | Hooks          | Pairing/RBAC
  Cache-aware    | Profiles        | Self-evolution | Memory providers
                            |
                            v
PLANE 4 — IRIS GOVERNANCE LAYER (our additions)
  Event log (append-only WAL) ----> Curator (batch PR generator)
                                            |
                                            v
  Sandbox dispatcher <- Reconciler <- Manifest in git (intent layer)
                            |
                            v
PLANE 5 — EXECUTION SUBSTRATE
  Sandbox pool (Daytona/gVisor/microVM, per-task ephemeral)
  Per-profile persistent volumes (~/.hermes/profiles/<name>/)
  pgvector with namespace-per-tenant
  Secrets: Vault / SOPS / cloud KMS
  Network egress allowlist per tenant
```

### Plane 1 — Observability

The unifying telemetry layer that cuts through every other plane.

| Source | Provides | Status |
|---|---|---|
| OpenTelemetry SDK in every iris-* wrapper + Hermes hooks | Distributed traces — orchestrator → subagent → tool call → MCP roundtrip in one timeline | net-new in V2 |
| Prometheus scraping LiteLLM, Hermes `/metrics` (v0.9+), Honcho, gateway, sandbox dispatcher | Per-agent latency p50/p99, error rate, token throughput, $/agent/hr | partial in V1 (LiteLLM only) |
| Loki receiving structured logs from every container | Searchable: "what did persona say to coder last Tuesday at 3pm?" | net-new in V2 |
| Grafana dashboards | Pre-built per-agent, per-user, per-tenant, fleet views | net-new in V2 |
| Mission Control fleet UI | Operator cockpit: agents, queue depth, cost rate, pending pairings | net-new in V2 |
| Audit log (Postgres append-only) | Compliance-grade immutable record, retention-policy controlled | net-new in V2 |

The trace ID flows through every layer:

```
user message
  arrives at Telegram adapter            [trace_id = T1]
  routed to persona profile              [span: persona.handle_message, parent T1]
  persona calls researcher via MCP       [span: persona.mcp_call]
  researcher receives MCP request        [span: researcher.mcp_serve]
  researcher calls Kimi via LiteLLM      [span: researcher.llm_call]
  researcher writes to Honcho dialectic  [span: researcher.honcho_conclude]
  response flows back                    [all spans nested under T1]
```

Open one trace in Grafana → see the entire decision flow across 4 services in one timeline.

### Plane 2 — Fleet orchestration

N independent Hermes profiles, each a fully-isolated agent with its own SOUL, skills, memory, cron, sessions. Coordination happens through three Hermes-native primitives:

- **MCP serve mode**: each profile registers itself as an MCP server. Other profiles list it in `mcp.yaml` and call it like any external tool.
- **Kanban**: shared task board across profiles. `coder` files a card, `ops` picks it up, both leave comments.
- **Honcho per-peer cards**: each user has one identity across all profiles. Talk to `persona` about your dog, `researcher` automatically knows the dog exists.

A small **fleet supervisor** sits above the profiles for personal use: routes user input to the right profile, collects telemetry from each, enforces tenant boundaries (in corporate mode).

### Plane 3 — Hermes native layers

The full utilization map. Bold = V2 begins using:

| Hermes feature | V1 | V2 |
|---|---|---|
| Skills 3-tier (builtin/optional/local) | partial | fully wired through manifest |
| **Curator** (stale 30d, archive 90d, LLM review pass) | unused | **core** — runs nightly per profile |
| **Periodic nudge** (every 15 tool calls, save workflow skill) | unused | **core** — drives autonomous skill creation |
| Honcho peer card + base context | running, partial | per-user identity layer per profile |
| **Honcho dialectic + `honcho_conclude`** | unused | **core** — every wrapper failure writes lesson here |
| Sessions FTS5 cross-session recall | implicit | promoted into curator's batch review |
| **Kanban** | unused | **core** — async cross-profile coordination |
| Plugins (Git-based) | partial | audit which 6/9 are used; disable rest |
| MCP servers (external) | wrapper exists | continues |
| **MCP serve mode** (Hermes AS server) | unused | **core** — cross-profile RPC |
| Hooks (pre/post tool call) | Presidio only | + OTel emitter + audit logger |
| Pairing / RBAC | pairing only | + Owner/Admin/User/Guest tiers (when #527 lands) |
| **Cache-aware deferred semantics** | unused | wrappers default `--deferred`, opt-in `--now` |
| **Profiles** | unused | adopt for personal team + corporate per-employee |
| Self-evolution (DSPy + GEPA) | not present | optional add-on for v2.5 |
| Memory providers (pluggable) | Honcho default | document swap to Mem0/Hindsight |

### Plane 4 — Iris governance layer

The GitOps split. **Iris stops touching git in real time.**

```
INTENT (slow, reviewed)             OBSERVATION (fast, autonomous)
git: declarative spec                event log: append-only WAL
- skills.yaml                        - user prompts
- pipelines.yaml                     - tool calls + outcomes
- integrations.yaml                  - memory writes
- guardrails.yaml                    - skill discoveries / failures
                                     - resource consumption
        ^                                    |
        |                                    | curator (periodic batch)
        | reconciler                         v
        |                              proposes intent diff
        |                              ONE PR per cadence
        +----------------------------- not per action
```

Every wrapper, every Hermes tool call, every memory write emits one event log row. No review gate. ms-scale latency. Once a day (or on demand), the Curator reads the log, summarizes, opens a single PR with structured manifest diffs and a narrative description. You review one well-written PR per cadence, not 20 stub branches.

The reconciler watches the manifest and reconciles runtime state (sandbox pool, MCP wiring, cron schedules) to match. Same shape as ArgoCD for Kubernetes.

### Plane 5 — Execution substrate

V1 ran everything inside the iris-gateway container. V2 splits:

- **Orchestrator** (per-profile gateway, persistent): receives input, plans, dispatches.
- **Sandbox pool** (per-task, ephemeral): executes the actual work.

Anything that *executes* — a tool call, a skill, a cron job's body, a package install — lands in a fresh sandbox. Daytona for personal-scale (Docker, sub-90ms), gVisor or Firecracker for corporate (hardware boundary).

```
Iris turn: "scrape the RSS feed"
  orchestrator: spawn sandbox with:
    - blogwatcher skill loaded
    - egress: theverge.com only
    - fs: /tmp + /workspace ro
    - timeout: 60s
    - budget: $0.05
  sandbox runs (~100ms cold start)
  emits result + events
  sandbox dies
```

Failed installs, runaway loops, broken skills cannot break the orchestrator. The five isolation layers (compute / fs / network / identity / memory) all live here.

---

## 2. Prerequisites

| Requirement | Personal mode | Corporate mode |
|---|---|---|
| OS | macOS or Linux | Linux preferred (k8s targets) |
| Docker Desktop | >= 4.30 | >= 4.30 (or k8s + containerd) |
| Disk | ~30 GB | ~50 GB + per-tenant volumes |
| RAM | 8 GB free | 4 GB per active profile |
| OpenRouter API key | required | required (or alternative providers) |
| Telegram / Discord tokens | optional | optional (per profile) |
| Claude Max plan | optional (sidecar) | optional (sidecar) |
| Daytona API key | optional in phase 5 | required in phase 5 |
| Vault / KMS | not required | required in phase 6 |
| OIDC provider (Keycloak / Auth0) | not required | required in phase 7 |

---

## 3. Quickstart (phases 1-4 only)

After implementation, the bring-up looks like:

```bash
# 1. Clone (same as V1)
git clone <YOUR_FORK_URL> iris && cd iris

# 2. Generate stack secrets
bash scripts/setup-secrets.sh

# 3. Add OpenRouter key + (optional) Telegram tokens to .env files
# Same as V1

# 4. Clone upstream Hermes + Honcho
git clone --depth 1 https://github.com/NousResearch/hermes-agent.git
git clone --depth 1 https://github.com/plastic-labs/honcho.git honcho-src

# 5. Choose your profile set (personal mode)
bash scripts/v2-init-profiles.sh persona researcher coder ops

# 6. Bring up the V2 stack (12 V1 containers + 5 V2 cross-cutting + N profile gateways)
make dev-v2

# 7. One-time per-profile virtual key minting + SOUL push
bash scripts/v2-mint-keys.sh

# 8. (Optional) Claude Code OAuth login
docker exec -it claude-cli claude
```

After step 6 you have:

- Mission Control at http://127.0.0.1:9120
- Grafana dashboards at http://127.0.0.1:3000
- LiteLLM admin at http://127.0.0.1:4000/ui (unchanged)
- N profile dashboards at http://127.0.0.1:9119 (unchanged) and http://127.0.0.1:9119/profile/<name>

Reach each profile from Telegram/Discord through their separate bot tokens, or all of them through the fleet supervisor.

---

## 4. Phase 1 — Observability Foundation

**Goal:** every iris-* wrapper, every Hermes tool call, every container emits structured telemetry to a shared Prometheus + Loki + OTel stack with Grafana on top. After this phase, "what is happening now" has one answer instead of five.

**Time:** ~3 days work + bake-in time.

### 1.1 Add the observability stack to compose

New compose file `observability/compose.yaml`:

```yaml
services:
  otel-collector:
    image: otel/opentelemetry-collector-contrib:0.95.0
    container_name: otel-collector
    restart: unless-stopped
    volumes:
      - ./observability/otel-config.yaml:/etc/otel-collector-config.yaml:ro
    command: ["--config=/etc/otel-collector-config.yaml"]
    networks: [frontend, backend]

  loki:
    image: grafana/loki:3.0.0
    container_name: loki
    restart: unless-stopped
    volumes:
      - loki_data:/loki
    networks: [backend]

  promtail:
    image: grafana/promtail:3.0.0
    container_name: promtail
    restart: unless-stopped
    volumes:
      - /var/lib/docker/containers:/var/lib/docker/containers:ro
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./observability/promtail-config.yaml:/etc/promtail/config.yaml:ro
    command: -config.file=/etc/promtail/config.yaml
    networks: [backend]

  grafana:
    image: grafana/grafana:11.0.0
    container_name: grafana
    restart: unless-stopped
    ports:
      - "127.0.0.1:3000:3000"
    environment:
      GF_AUTH_ANONYMOUS_ENABLED: "true"
      GF_AUTH_ANONYMOUS_ORG_ROLE: Viewer
      GF_AUTH_BASIC_ENABLED: "true"
    volumes:
      - grafana_data:/var/lib/grafana
      - ./observability/grafana/provisioning:/etc/grafana/provisioning:ro
      - ./observability/grafana/dashboards:/var/lib/grafana/dashboards:ro
    depends_on: [prometheus, loki]
    networks: [frontend, backend]

volumes:
  loki_data:
  grafana_data:
```

Add `observability/compose.yaml` to the top-level `compose.yaml` `include:` list.

### 1.2 OTel collector config

`observability/otel-config.yaml` (excerpt):

```yaml
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318

processors:
  batch:
    timeout: 10s
  attributes:
    actions:
      - key: tenant
        action: insert
        from_context: tenant_id
      - key: profile
        action: insert
        from_context: profile_name

exporters:
  prometheus:
    endpoint: 0.0.0.0:8889
  loki:
    endpoint: http://loki:3100/loki/api/v1/push
  otlphttp/traces:
    endpoint: http://tempo:4318  # optional traces backend (phase 6)

service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [batch, attributes]
      exporters: [otlphttp/traces]
    metrics:
      receivers: [otlp]
      processors: [batch]
      exporters: [prometheus]
    logs:
      receivers: [otlp]
      processors: [batch]
      exporters: [loki]
```

### 1.3 Wire OTel into iris-* wrappers

Each wrapper (iris-learn, iris-cron, iris-skill, iris-mcp) gains a small Python helper called from its bash bottom-half:

```python
# iris/bin/_otel_emit.py
"""Shared OTel emitter used by iris-* wrappers.

Called at start, on each tool subprocess invocation, and on completion.
Span attributes carry: profile, action, subject, outcome, tenant, cost_usd.
"""
from opentelemetry import trace
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter

# ... initialization ...
tracer = trace.get_tracer("iris-wrapper")

def emit_event(category, action, subject, outcome, **attrs):
    """Convenience: emit a single span with these attributes."""
    with tracer.start_as_current_span(f"{category}.{action}") as span:
        span.set_attribute("subject", subject)
        span.set_attribute("outcome", outcome)
        for k, v in attrs.items():
            span.set_attribute(k, v)
```

Each wrapper sources this and calls `_otel_emit.py` from key points. Costs ~10 lines per wrapper; the aggregate gives complete distributed traces.

### 1.4 Hermes-side instrumentation

Hermes `>= v0.9` exposes `/metrics` natively. Configure prometheus.yml to scrape it:

```yaml
- job_name: hermes-gateway
  static_configs:
    - targets:
        - "iris-gateway-persona:9090"
        - "iris-gateway-researcher:9090"
        - "iris-gateway-coder:9090"
        - "iris-gateway-ops:9090"
```

For pre-v0.9 Hermes, write a small `hermes-metrics-shim` Python sidecar that polls `hermes status --json` and exposes Prometheus textfile metrics.

### 1.5 The first three Grafana dashboards

Pre-build and ship in `observability/grafana/dashboards/`:

1. **`fleet-overview.json`** — top-level. Active profiles, requests/min per profile, cost rate $/hr per profile, error rate, queue depth.
2. **`agent-detail.json`** — drill into one profile. Tool call latency p50/p99 by tool name. Skill invocation counts. Honcho memory write rate. Subagent fanout.
3. **`audit-search.json`** — Loki log search. "Show all calls by user X across all profiles in the last 24h." Pre-filtered by trace ID.

### 1.6 Cache-aware semantics in wrappers

Add `--deferred` (default) and `--now` flags to each wrapper.

```bash
iris-learn python httpx "needed for X"           # deferred — recorded; takes effect next session
iris-learn python httpx "needed for X" --now     # immediate — busts prompt cache
iris-cron add "0 9 * * 1" "..." --name x         # deferred — manifest written, cron registered next boot
iris-cron add "0 9 * * 1" "..." --name x --now   # immediate — cron registered now
```

Default behavior: append to event log + write to manifest, but **do not run reconcile**. Next session start picks it up. The `--now` flag triggers immediate reconcile, busting the prompt cache. Hermes's [official guidance](https://hermes-agent.nousresearch.com/docs/) explicitly recommends this pattern.

### 1.7 Verification

```bash
# 1. All planes 1 containers up
docker compose ps | grep -E "otel-collector|loki|promtail|grafana"
#   should show 4 services Up

# 2. OTel collector receiving spans
curl -s http://127.0.0.1:8889/metrics | grep otelcol_exporter_sent_spans_total
#   should show non-zero counter

# 3. Loki receiving logs
docker compose exec loki wget -qO- 'http://localhost:3100/loki/api/v1/query?query={container="iris-gateway"}' | head
#   should return JSON with log entries

# 4. Grafana dashboards loaded
curl -s http://127.0.0.1:3000/api/search | grep fleet-overview
#   should return the dashboard meta

# 5. Trace from a wrapper run lands in OTel
docker compose exec -T --user hermes iris-gateway iris-learn python click --now
#   then check Grafana > Explore > traces (or jaeger if added)
#   should show one trace with ~3 spans (wrapper start, install, commit)

# 6. Cache-aware default — wrapper without --now does NOT trigger reconcile
docker compose exec -T --user hermes iris-gateway iris-learn python websockets
docker compose logs iris-gateway --since 30s | grep iris-reconcile
#   should show NOTHING — reconcile didn't fire (deferred semantics)
```

---

## 5. Phase 2 — Self-Learning Loop

**Goal:** wire failure-to-Honcho-dialectic, periodic-nudge skill creation, and Hermes Curator into Iris's daily operation. After this phase, Iris remembers her own failures across sessions and her skill library grows organically.

**Time:** ~5 days.

### 2.1 Wire failures into Honcho dialectic

Every wrapper's failure path gets a `honcho_conclude` call:

```python
# iris/bin/_honcho_conclude.py
"""Record a structured fact into Honcho dialectic memory.

Called from wrapper failure handlers so the agent learns 'X doesn't exist'
or 'Y requires --force' without needing to repeat the discovery."""

import os, sys, requests
HONCHO_URL = os.environ.get("HONCHO_API_BASE", "http://honcho-api:8000")
PEER_ID = os.environ.get("IRIS_BOT_PEER_ID", "iris-bot")

def record_failure(category, subject, error_signature, lesson):
    """Append a typed failure conclusion to the agent's dialectic memory."""
    payload = {
        "peer_id": PEER_ID,
        "type": "failure",
        "category": category,        # skill | package | mcp | cron
        "subject": subject,          # the name attempted
        "error": error_signature,    # short error class
        "lesson": lesson,            # the durable lesson
    }
    requests.post(f"{HONCHO_URL}/conclusions", json=payload, timeout=5)
```

Wrappers call this on every failure path. Example for iris-skill:

```bash
if printf '%s' "$OUT" | grep -qE "Installation cancelled|^Error: "; then
    /opt/hermes/.venv/bin/python /usr/local/bin/_honcho_conclude.py \
      skill "$NAME" "not_in_registry" "skill '$NAME' was not found in any source — try a different name or check 'hermes skills search' first"
    exit 1
fi
```

Next session, when Iris is deciding what to install, Honcho's dialectic context surfaces the conclusion automatically — she won't try the same dead name again.

### 2.2 Enable Hermes Curator on a schedule

Hermes's Curator is built in but not scheduled. Add a daily cron entry per profile:

```bash
# Per-profile, scheduled by iris-cron
iris-cron add "0 3 * * *" \
  "Run hermes curator for this profile. Review user-authored skills; archive stale ones (>30d unused), consolidate overlapping ones, patch underperforming ones." \
  --name nightly-curator \
  --skill curator
```

The curator runs as Iris herself (uses an LLM pass). It writes its actions to the event log. Output: a daily summary card on the Kanban board for human review.

### 2.3 Periodic nudge

Hermes ships a periodic nudge that fires every 15 tool calls. Configure in each profile's `config.yaml`:

```yaml
periodic_nudge:
  enabled: true
  interval_tool_calls: 15
  prompt: |
    Pause and reflect on the last 15 tool calls.
    1. Did anything work that should become a reusable skill?
    2. Did any tool fail in a way you should remember for next time?
       Use honcho_conclude to record the lesson.
    3. Should anything land in the manifest? If so, queue a deferred
       iris-* wrapper invocation (default behavior — no cache bust).
```

Effect: skill creation becomes ambient. Iris won't need explicit `iris-skill install` invocations from the user — she does it autonomously when the workflow proves useful.

### 2.4 Verification

```bash
# 1. Honcho conclusion recorded after a deliberate failure
docker compose exec -T --user hermes iris-gateway iris-skill install nonexistent-skill-xyz
#   wrapper aborts with "failed", honcho_conclude is called

curl -s http://127.0.0.1:8000/conclusions?peer_id=iris-bot | tail -5
#   should show the failure conclusion JSON

# 2. Next session, Iris doesn't retry the same name
docker compose exec -T --user hermes iris-gateway /opt/hermes/.venv/bin/hermes -z \
  "I want to install something for embodied AI. What should I try?"
#   she should NOT propose 'nonexistent-skill-xyz' (or whatever you tried)
#   because the dialectic context surfaces the failure

# 3. Curator scheduled
docker compose exec -T --user hermes iris-gateway hermes cron list | grep nightly-curator

# 4. Periodic nudge active
grep -A 3 "periodic_nudge" /opt/data/config.yaml | head
#   should show enabled: true
```

---

## 6. Phase 3 — Iris Curator + GitOps split

**Goal:** Replace the per-action GitHub flow with an event log + batch-PR Curator. After this phase, Iris's day-to-day actions land in `/opt/data/iris-events.db`, not git, and a single curated PR per cadence captures intent changes.

**Time:** ~5 days.

### 3.1 Event log schema

`/opt/data/iris-events.db` — SQLite WAL mode, single-writer per profile (event-emitter is per-profile already).

```sql
CREATE TABLE events (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  ts          TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  profile     TEXT NOT NULL,
  tenant      TEXT,                          -- NULL in personal mode
  actor       TEXT NOT NULL,                 -- iris | curator | user-id
  category    TEXT NOT NULL,                 -- skill | cron | mcp | package | memory | tool_call | mcp_serve
  action      TEXT NOT NULL,                 -- install | uninstall | invoke | succeed | fail | propose
  subject     TEXT,                          -- the name/id of what was acted on
  payload     TEXT,                          -- JSON, full structured detail
  outcome     TEXT NOT NULL,                 -- ok | error | timeout | cancelled
  trace_id    TEXT,                          -- correlation across services
  cost_usd    REAL,                          -- per-call cost
  tokens_in   INTEGER,
  tokens_out  INTEGER
);
CREATE INDEX events_ts ON events(ts);
CREATE INDEX events_actor_ts ON events(actor, ts);
CREATE INDEX events_category_ts ON events(category, ts);
CREATE INDEX events_trace ON events(trace_id);
```

For corporate mode, this schema migrates to Postgres (same column shape).

### 3.2 Event emitter

`iris/bin/_event_log.py`:

```python
"""Append a row to /opt/data/iris-events.db. Used by every iris-* wrapper
and by Hermes hooks. Sub-millisecond latency. No review gate."""

import sqlite3, json, os
from datetime import datetime

DB_PATH = os.environ.get("IRIS_EVENT_LOG", "/opt/data/iris-events.db")
PROFILE = os.environ.get("HERMES_PROFILE", "default")
TENANT  = os.environ.get("IRIS_TENANT")  # None in personal mode

def emit(category, action, subject=None, outcome="ok", payload=None,
         trace_id=None, cost_usd=None, tokens_in=None, tokens_out=None,
         actor="iris"):
    with sqlite3.connect(DB_PATH, isolation_level=None, timeout=10) as db:
        db.execute("PRAGMA journal_mode=WAL")
        db.execute("""
            INSERT INTO events
              (profile, tenant, actor, category, action, subject, payload,
               outcome, trace_id, cost_usd, tokens_in, tokens_out)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
        """, (PROFILE, TENANT, actor, category, action, subject,
              json.dumps(payload) if payload else None,
              outcome, trace_id, cost_usd, tokens_in, tokens_out))
```

### 3.3 Wrappers route through event log; remove per-action git commits

Refactor each wrapper:

| V1 behavior | V2 behavior |
|---|---|
| Every action → branch + commit on iris-self/* | Every action → event log row |
| Stash dance to preserve user state | None needed — no branch switch |
| Reconcile triggered immediately | Deferred by default; `--now` for opt-in immediate |
| Manifest write at action time | Deferred — manifest written by Curator at batch time |

The wrappers shrink dramatically. `iris-learn` becomes:

```bash
#!/usr/bin/env bash
set -euo pipefail

ECO="${1:?usage: iris-learn <eco> <pkg> [reason]}"
PKG="${2:?usage: iris-learn <eco> <pkg> [reason]}"
REASON="${3:-}"

# 1. Install (with sandbox dispatch in phase 5; for now, in-process)
case "$ECO" in
  apt)    sudo apt-get install -y --no-install-recommends "$PKG" ;;
  python) uv pip install --quiet --python /opt/hermes/.venv/bin/python "$PKG" ;;
  npm)    npm install -g --silent "$PKG" ;;
esac

# 2. Emit event (no git, no branch, no commit)
/opt/hermes/.venv/bin/python /usr/local/bin/_event_log.py \
  --category package --action install --subject "$ECO:$PKG" \
  --payload "{\"reason\": \"$REASON\"}" --outcome ok
```

That's the entire wrapper. No stash dance, no commit, no MSG construction. The Curator handles all the manifest+git work in batch.

### 3.4 Iris Curator (the batch PR generator)

A separate service in compose:

```yaml
iris-curator:
  build:
    context: .
    dockerfile: iris/Dockerfile.curator
  container_name: iris-curator
  restart: unless-stopped
  volumes:
    - data:/opt/data:ro              # read events
    - ${IRIS_REPO:-${HOME}/personal_assistant/iris}:/repo:rw  # write PRs
    - ~/.gh-token:/run/secrets/gh-token:ro
  environment:
    CURATOR_CADENCE: "0 4 * * *"     # daily 4am
    LITELLM_BASE: http://litellm:4000/v1
    LITELLM_KEY: ${IRIS_VIRTUAL_KEY}
  networks: [backend, frontend]
```

The curator process:

```python
# iris/curator/run.py — pseudocode

def curate():
    # 1. Read events since last curation cycle
    events = read_events_since(last_cycle_end)

    # 2. Group by category and analyze
    summary = analyze_with_llm(events, prompt="""
      You're reviewing Iris's actions over the last 24h.
      Categorize as: routine (no action) | propose-promotion (worth manifesting)
                   | propose-archival (stale) | escalate (anomaly).
      For propose-promotion: write the manifest diff and a 1-sentence reason.
      For propose-archival: list the entries with last-seen timestamps.
      For escalate: describe the anomaly with trace IDs.
    """)

    # 3. If nothing to propose, skip
    if not summary.has_proposals():
        return

    # 4. Open a single PR with the full distilled change
    branch = f"iris-curator/distill-{date.today()}"
    apply_manifest_diffs(branch, summary.diffs)
    commit_on_branch(branch, msg=summary.narrative)
    open_pr(branch, title=summary.title, body=summary.narrative)
```

Expected output: one PR per cadence titled `iris-curator: weekly distill — 2026-05-10` with body like:

```markdown
## Summary
Iris exercised 47 capabilities this week. Three are worth promoting to the manifest.

## Proposed promotions
- skills.json: add `arxiv-watch` (used 12x this week, for daily research scan)
- cron.yaml: add `weekly-paper-digest` (already running ad-hoc; codify the schedule)
- mcp.yaml: add `notion-personal-tasks` (used in 8 conversations)

## Proposed archivals
- skills.json: archive `embodied-ai-news` (never used since install — failed-import pattern)

## Anomalies
None this cycle.

## Trace IDs for review
- arxiv-watch: T-2026-05-08-3f2 ... (5 entries)
```

### 3.5 Reconciler (controller)

A small pluggable controller that watches the manifest and brings runtime to spec.

```
iris/reconciler/
  main.py                # main loop; watches manifest, dispatches handlers
  handlers/
    skills.py            # uses hermes skills snapshot import
    cron.py              # uses hermes cron create/remove
    mcp.py               # uses hermes mcp add/remove
    packages.py          # uses uv/apt
```

Replaces the four separate reconcile scripts in V1 with one cohesive controller. Same handler shape, single codebase.

### 3.6 Verification

```bash
# 1. Event log writes happen
docker compose exec -T --user hermes iris-gateway iris-cron add "every 24h" "test" --name v2-test
sqlite3 /opt/data/iris-events.db "SELECT category, action, subject FROM events ORDER BY ts DESC LIMIT 1"
#   should show: cron|install|v2-test

# 2. NO git branch was created (deferred default)
git branch | grep cron-add-v2-test || echo "ok — no branch (deferred semantics working)"

# 3. Force the curator manually
docker compose exec iris-curator python /opt/iris-curator/run.py --once

# 4. PR was opened for review
gh pr list --head 'iris-curator/distill-*' --json number,title

# 5. Verify reconciler picks up manifest changes
# (after merging the curator PR)
git pull origin main
docker compose restart iris-reconciler
docker compose logs iris-reconciler --since 1m | grep "applied"
```

---

## 7. Phase 4 — Personal multi-profile fleet

**Goal:** N independent Hermes profiles (persona, researcher, coder, ops) running on the same machine, each with its own SOUL, skills, memory, and addressable via Telegram + the dashboard. Coordination through MCP serve mode + Kanban.

**Time:** ~5 days.

### 4.1 Per-profile directory layout

```
iris/iris-config/profiles/
  persona/
    SOUL.md              # warm, conversational
    config.template.yaml # references the persona's virtual key
  researcher/
    SOUL.md              # rigorous, citation-aware
    config.template.yaml
  coder/
    SOUL.md              # terse, defers to claude-cli
    config.template.yaml
  ops/
    SOUL.md              # checklist-driven, dry humor
    config.template.yaml
```

Each profile gets its own LiteLLM virtual key (separate cost attribution per role) and its own Hermes profile dir at `/opt/data/profiles/<name>/`.

### 4.2 Compose changes

The single `iris-gateway` service multiplies into N. Either:

**Option A — N services in compose (verbose, explicit):**

```yaml
services:
  iris-persona:
    image: iris-bridge:local
    container_name: iris-persona
    environment:
      HERMES_PROFILE: persona
    command: ["gateway", "run", "--profile", "persona"]
    volumes:
      - data_persona:/opt/data
    ports:
      - "127.0.0.1:9119:9119"     # only one profile gets the dashboard port

  iris-researcher:
    image: iris-bridge:local
    container_name: iris-researcher
    environment:
      HERMES_PROFILE: researcher
    command: ["gateway", "run", "--profile", "researcher"]
    volumes:
      - data_researcher:/opt/data

  # ... coder, ops similar
```

**Option B — `deploy.replicas` style with per-replica config (compact):**

Keep one service definition; mount per-profile volumes via env var. Cleaner but less Docker Compose-native; more natural in K8s.

For personal mode, Option A is recommended (1 file, easy to read). For corporate, Option B (or full K8s manifests) is recommended.

### 4.3 Per-profile virtual keys + SOUL push

Update `mint-iris-key.sh` to operate per-profile:

```bash
bash scripts/v2-mint-keys.sh persona researcher coder ops
#   mints 4 separate LiteLLM virtual keys
#   writes IRIS_VIRTUAL_KEY_PERSONA=..., IRIS_VIRTUAL_KEY_RESEARCHER=..., etc.
#   renders 4 separate config.yaml files
#   pushes each into the matching profile's /opt/data/config.yaml
#   restarts each profile gateway
```

LiteLLM dashboard now shows per-profile spend.

### 4.4 MCP serve mode — cross-profile RPC

Each profile gateway runs `hermes mcp serve` on a unique unix socket or TCP port:

```yaml
services:
  iris-persona:
    # ... as above ...
    command: |
      sh -c "
        hermes mcp serve --bind 0.0.0.0:7100 &
        hermes gateway run --profile persona
      "
```

Each profile's `mcp.yaml` lists the others:

```yaml
# iris-persona's mcp.yaml
servers:
  - name: researcher
    url: http://iris-researcher:7100
  - name: coder
    url: http://iris-coder:7100
  - name: ops
    url: http://iris-ops:7100
```

Now `persona` can call `mcp_call("researcher", "honcho_search", "company holidays")` and get the answer from researcher's memory.

### 4.5 Kanban — async cross-profile task board

Hermes ships Kanban natively. The kanban DB lives in each profile's `/opt/data/kanban.db`. For cross-profile, mount a shared kanban volume:

```yaml
volumes:
  shared_kanban:

services:
  iris-persona:
    volumes:
      - shared_kanban:/opt/data/kanban-shared:rw
    environment:
      HERMES_KANBAN_PATH: /opt/data/kanban-shared/board.db

  # same mount for researcher, coder, ops
```

Now any profile can:

```python
hermes kanban add "investigate disk usage on /var/lib" --assigned coder
hermes kanban list --assigned coder
hermes kanban comment <card-id> "found 30GB of docker layers"
hermes kanban close <card-id>
```

The shared board becomes the async coordination layer.

### 4.6 Telegram routing

For personal mode, two patterns:

**Pattern A — one Telegram bot per profile** (simple, recommended):

Each profile has its own `TELEGRAM_BOT_TOKEN_<NAME>` in `.env`. Different bots in your Telegram. `@iris_persona_bot`, `@iris_researcher_bot`, etc.

**Pattern B — one bot, slash-command routing** (clever, fragile):

Single `@iris_bot`. Messages prefixed `/persona ...` route to persona. Requires a small fleet supervisor in front of the gateways.

### 4.7 Verification

```bash
# 1. All profiles up
docker compose ps | grep iris-
#   should show 4 profile gateways

# 2. Per-profile cost in LiteLLM
curl -s http://127.0.0.1:4000/v1/spend/keys -H "Authorization: Bearer $LITELLM_MASTER_KEY"
#   should show 4 keys, separate spend

# 3. Profile-to-profile MCP call
docker compose exec -T --user hermes iris-persona /opt/hermes/.venv/bin/hermes -z \
  "Use the researcher MCP server to search Honcho memory for 'arxiv'."
#   trace in Grafana should show: persona -> mcp_call -> researcher.mcp_serve -> honcho_search

# 4. Shared kanban
docker compose exec -T --user hermes iris-coder hermes kanban add "test card from coder" --assigned ops
docker compose exec -T --user hermes iris-ops hermes kanban list
#   ops should see the card coder filed

# 5. Trace IDs span profiles
# In Grafana, search for traces with multiple profile spans nested
```

---

## 8. Phase 5 — Sandbox dispatch

**Goal:** Per-execution isolation. Tool calls, skills, cron jobs, package installs all run in fresh ephemeral sandboxes. Failed installs cannot break the orchestrator. The five isolation layers (compute / fs / network / identity / memory) are physically enforced.

**Time:** ~10 days.

### 8.1 Choose sandbox runtime

| Runtime | Best for | Cold start | Cost |
|---|---|---|---|
| Daytona | personal-mode start, dev | 27-90 ms | $0.067/hr |
| E2B (Firecracker microVM) | corporate, untrusted code | 90-150 ms | $0.05/hr |
| gVisor (self-hosted on K8s) | corporate at scale | 100-200 ms | infra cost only |
| Modal | python-heavy GPU workloads | sub-100 ms | per-second |
| Northflank | long-running stateful sandboxes | sub-200 ms | per-hour |

For phase 5 personal mode, **Daytona** is recommended (simple, fast, can self-host). For phase 7 corporate, **gVisor on K8s with Agent Sandbox primitive**.

### 8.2 Sandbox dispatcher service

```yaml
iris-dispatcher:
  build:
    context: .
    dockerfile: iris/Dockerfile.dispatcher
  container_name: iris-dispatcher
  restart: unless-stopped
  environment:
    SANDBOX_RUNTIME: daytona     # or e2b | gvisor
    DAYTONA_API_KEY: ${DAYTONA_API_KEY}
    POOL_MIN: 2
    POOL_MAX: 20
  networks: [backend]
```

The dispatcher exposes an internal API:

```
POST /sandbox/spawn
  body: { profile, task_id, image, command, fs_mode, egress_allowlist, timeout_s, budget_usd }
  returns: { sandbox_id, endpoint }

POST /sandbox/<id>/exec
  body: { cmd, env }
  returns: { stdout, stderr, exit_code, cost_usd, duration_ms }

DELETE /sandbox/<id>
```

### 8.3 Wrappers route execution through dispatcher

`iris-learn` becomes:

```bash
# iris-learn python httpx
SANDBOX=$(curl -s POST http://iris-dispatcher:8080/sandbox/spawn \
  -d '{"profile":"persona","task_id":"learn-py-httpx","image":"python:3.13-slim",
       "egress_allowlist":["pypi.org","files.pythonhosted.org"],
       "fs_mode":"ephemeral","timeout_s":60,"budget_usd":0.05}')

curl -s POST http://iris-dispatcher:8080/sandbox/$SANDBOX/exec \
  -d '{"cmd":"pip install --target /workspace httpx","env":{}}'

# Sandbox dies; if successful, copy artifact to /opt/data/profile-libs/persona/
# Emit event
```

**Failed install in the sandbox cannot affect the orchestrator's venv.**

### 8.4 Per-tenant egress allowlists

Default per-task egress: deny-all. Per-skill or per-pipeline, declare the allowlist:

```yaml
# In iris-config/skills.yaml metadata
- name: blogwatcher-rss
  egress_allowlist:
    - feeds.bloomberg.com
    - rss.cnn.com
    - theverge.com
```

Sandbox dispatcher passes the allowlist to the runtime; the sandbox's network namespace enforces it. **No exfiltration to attacker-controlled domains, even if a skill is compromised.**

### 8.5 Verification

```bash
# 1. Dispatcher running
docker compose ps iris-dispatcher

# 2. Spawn a sandbox manually
curl -X POST http://127.0.0.1:8080/sandbox/spawn -d '{...}'
#   returns sandbox_id

# 3. Failed install cannot affect orchestrator
docker compose exec -T --user hermes iris-gateway iris-learn python broken-package-name-xyz
#   sandbox creates, install fails, sandbox dies, orchestrator's venv is unchanged

# 4. Egress allowlist enforced
# Spawn sandbox with allowlist=[github.com]; try curl to gitlab.com → fails
# try curl to github.com → succeeds
```

---

## 9. Phase 6 — Mission Control + audit log

**Goal:** Operator cockpit for the agent fleet + compliance-grade audit log. After this phase, you can answer "who did what when" for any auditor.

**Time:** ~10 days.

### 9.1 Mission Control service

`mission-control` is open-source (referenced in our research). Self-hosted, SQLite-powered. Add to compose:

```yaml
mission-control:
  image: ghcr.io/openagentplatform/mission-control:latest
  container_name: mission-control
  restart: unless-stopped
  ports:
    - "127.0.0.1:9120:8080"
  environment:
    MC_BACKEND_URL: http://iris-supervisor:8000
    MC_LITELLM_URL: http://litellm:4000
    MC_PROMETHEUS_URL: http://prometheus:9090
  networks: [frontend, backend]
```

Mission Control's UI shows:

- All N profile gateways with health, requests/min, cost rate
- Pending pairings queue (cross-profile)
- Pending Curator PRs awaiting review
- Per-skill performance over time
- Per-tenant cost attribution

### 9.2 Audit log Postgres

Separate from event log (which is operational). Audit log is **append-only, retention-policy controlled, tamper-evident**:

```yaml
audit-db:
  image: postgres:16
  container_name: audit-db
  restart: unless-stopped
  environment:
    POSTGRES_DB: audit
    POSTGRES_USER: audit
    POSTGRES_PASSWORD: ${AUDIT_DB_PASSWORD}
  volumes:
    - audit_postgres_data:/var/lib/postgresql/data
  networks: [backend, data]
```

Schema:

```sql
CREATE TABLE audit_log (
  id          BIGSERIAL PRIMARY KEY,
  ts          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  tenant      TEXT NOT NULL,
  profile     TEXT NOT NULL,
  actor_type  TEXT NOT NULL,                -- user | agent | curator | system
  actor_id    TEXT NOT NULL,
  action      TEXT NOT NULL,                -- read | write | install | delete | invoke
  resource_type TEXT NOT NULL,              -- skill | memory | mcp_server | secret | config
  resource_id TEXT NOT NULL,
  outcome     TEXT NOT NULL,
  trace_id    TEXT,
  pii_redacted BOOLEAN NOT NULL DEFAULT FALSE,
  payload     JSONB
);

-- WAL-only — no UPDATE, no DELETE
REVOKE UPDATE, DELETE ON audit_log FROM PUBLIC;
GRANT INSERT, SELECT ON audit_log TO audit_writer;
GRANT SELECT ON audit_log TO audit_reader;
```

Retention policy: configurable. Personal: 90 days. Corporate: 7 years (HIPAA) or 3 years (SOC2).

### 9.3 Audit emitter as a Hermes hook

Every Hermes tool call's `post_tool_call` hook writes to audit log:

```python
# iris/hooks/audit_emit.py
"""post_tool_call hook — record the action in the audit log."""
import psycopg, json, os, sys

PG = psycopg.connect(os.environ["AUDIT_DB_URL"])

def main():
    event = json.load(sys.stdin)
    tool = event["tool"]
    args = event["args"]
    result = event["result"]
    trace_id = event.get("trace_id")

    PG.execute("""
        INSERT INTO audit_log (tenant, profile, actor_type, actor_id, action,
                               resource_type, resource_id, outcome, trace_id,
                               pii_redacted, payload)
        VALUES (%s, %s, 'agent', %s, %s, %s, %s, %s, %s, %s, %s)
    """, (
        os.environ.get("IRIS_TENANT"),
        os.environ["HERMES_PROFILE"],
        os.environ["IRIS_BOT_PEER_ID"],
        action_from_tool(tool),
        resource_type_from_tool(tool),
        args.get("name") or args.get("path") or "",
        "ok" if result["ok"] else "error",
        trace_id,
        result.get("pii_was_redacted", False),
        json.dumps({"args": args, "result_summary": result.get("summary")})
    ))
    PG.commit()
```

Every tool call → one audit row. Queries:

```sql
-- Show all reads on user X's data in the last 90 days
SELECT * FROM audit_log
WHERE action = 'read' AND payload->>'subject' = 'user-X' AND ts > NOW() - INTERVAL '90 days'
ORDER BY ts DESC;

-- Show all installs by a specific profile last week
SELECT * FROM audit_log
WHERE profile = 'persona' AND action = 'install' AND ts > NOW() - INTERVAL '7 days';

-- Per-tenant cost attribution
SELECT tenant, COUNT(*), SUM(payload->>'cost_usd')::FLOAT
FROM audit_log
WHERE ts > NOW() - INTERVAL '30 days'
GROUP BY tenant ORDER BY 3 DESC;
```

### 9.4 Compliance dashboards in Grafana

Three dashboards backed by audit-db (Postgres data source):

1. **Compliance — Access Patterns**: who accessed what, when. Per-user activity heatmaps.
2. **Compliance — Data Egress**: every cloud call, with Presidio redaction rate.
3. **Compliance — Privilege Changes**: every skill install, MCP server add, RBAC change.

### 9.5 Verification

```bash
# 1. Mission Control accessible
curl -s http://127.0.0.1:9120/api/health
#   should return { "status": "ok" }

# 2. Audit row written for every tool call
docker compose exec -T --user hermes iris-persona iris-skill install rectifier
psql -h 127.0.0.1 -U audit -d audit -c "SELECT * FROM audit_log ORDER BY ts DESC LIMIT 5"
#   should show the install row

# 3. Audit log is append-only — UPDATEs blocked
psql -h 127.0.0.1 -U audit -d audit -c "UPDATE audit_log SET outcome='ok' WHERE id=1"
#   should fail with "permission denied for table audit_log"

# 4. Compliance dashboards render
curl -s http://127.0.0.1:3000/api/dashboards/uid/compliance-access | head
```

---

## 10. Phase 7 — Multi-tenant (corporate)

**Goal:** Hard tenant isolation across all 5 layers. After this phase, the architecture is corporate-grade with audit, RBAC, OIDC, and per-tenant compute / FS / network / identity / memory boundaries.

**Time:** ~15 days.

### 10.1 Tenant column everywhere

The `events` and `audit_log` tables already have `tenant` columns. Now all reads and writes are scoped:

```python
# Every database read filters by tenant
SELECT * FROM audit_log WHERE tenant = current_user_tenant()

# Every Honcho query is namespaced
honcho_search(tenant=current_user_tenant(), query=...)

# Every sandbox spawn carries the tenant
spawn_sandbox(tenant=current_user_tenant(), ...)
```

The `current_user_tenant()` resolution comes from the OIDC JWT claim.

### 10.2 OIDC + RBAC

Add `oauth2-proxy` (or Keycloak) as an auth gateway in front of Mission Control + dashboards:

```yaml
oidc-proxy:
  image: quay.io/oauth2-proxy/oauth2-proxy:v7.6.0
  container_name: oidc-proxy
  restart: unless-stopped
  environment:
    OAUTH2_PROXY_PROVIDER: keycloak-oidc
    OAUTH2_PROXY_CLIENT_ID: iris-fleet
    OAUTH2_PROXY_OIDC_ISSUER_URL: ${OIDC_ISSUER_URL}
    OAUTH2_PROXY_UPSTREAMS: http://mission-control:8080,http://grafana:3000
  ports:
    - "127.0.0.1:443:4180"
  networks: [frontend]
```

RBAC tiers (matching Hermes issue #527):

| Tier | Can | Cannot |
|---|---|---|
| Owner | Anything | — |
| Admin | All except change RBAC | Change tenant boundaries |
| User | Use their own tenant agents | See other tenants' data |
| Guest | Read-only for assigned tenant | Write any state |

### 10.3 Secrets management

`.env` files retire in favor of Vault or cloud KMS:

```yaml
vault:
  image: hashicorp/vault:1.16
  container_name: vault
  restart: unless-stopped
  environment:
    VAULT_DEV_ROOT_TOKEN_ID: ${VAULT_ROOT_TOKEN}
  cap_add: [IPC_LOCK]
  ports:
    - "127.0.0.1:8200:8200"
  networks: [backend]
```

Each profile gateway gets a Vault Agent sidecar that retrieves secrets at startup.

### 10.4 Per-tenant pgvector namespace

Honcho's pgvector schema migrates from one shared `peers` table to one schema per tenant:

```sql
CREATE SCHEMA tenant_acme;
CREATE TABLE tenant_acme.peers (...);

CREATE SCHEMA tenant_initech;
CREATE TABLE tenant_initech.peers (...);

-- Honcho queries are routed to the correct schema based on JWT
```

**No cross-tenant memory bleed.** A user in tenant Acme cannot ever surface in tenant Initech's dialectic context.

### 10.5 K8s deployment manifests

In `k8s/` directory, Helm chart or Kustomize overlays:

```
k8s/
  base/
    iris-supervisor.yaml         # one per cluster
    iris-curator.yaml            # one per cluster
    iris-dispatcher.yaml         # one per cluster
    profile-gateway.yaml         # template; one StatefulSet per tenant×profile
    persistent-volumes.yaml      # per-tenant PVs
    network-policies.yaml        # egress allowlists
  overlays/
    dev/
    staging/
    prod/
```

Use **Agent Sandbox primitive** (Kubernetes SIG Apps) for the sandbox pool — designed exactly for this.

### 10.6 Verification

```bash
# 1. Tenant isolation in DB
psql audit-db -c "SELECT DISTINCT tenant FROM audit_log"
#   should show all configured tenants

# 2. JWT claim resolution
curl -H "Authorization: Bearer $tenant_acme_jwt" \
  http://127.0.0.1:443/api/profiles
#   should return only tenant Acme's profiles, never Initech's

# 3. RBAC enforced
# A Guest user attempts to write — fails with 403

# 4. Cross-tenant memory query — blocked
# tenant_acme's iris instance attempts honcho_search across all tenants → returns only Acme's

# 5. Sandbox isolation
# tenant_acme sandbox cannot reach tenant_initech's network namespace
```

---

## 11. Reference

### File and directory layout

```
iris/                             # repo root
  AGENTS.md                       # for human authors of this repo
  CLAUDE.md                       # CLAUDE Code config (existing)
  INSTALL.md                      # V1 install guide (existing, kept for reference)
  V2_INSTALL.md                   # this file
  README.md                       # updated for V2

  compose.yaml                    # top-level; includes the per-area sub-compose files
  compose.prod.yaml               # production hardening
  compose.override.yaml           # dev-mode overrides

  iris/                           # iris-specific runtime
    Dockerfile.iris-bridge        # the core image (existing)
    Dockerfile.curator            # NEW — curator service image
    Dockerfile.dispatcher         # NEW — sandbox dispatcher
    Dockerfile.supervisor         # NEW — fleet supervisor
    iris-bridge-entrypoint.sh     # existing
    presidio-mask.py              # existing
    claude-wrapper.sh             # existing
    bin/
      iris-learn                  # refactored: emits events, no git
      iris-cron                   # refactored: emits events, no git
      iris-skill                  # refactored: emits events, no git
      iris-mcp                    # refactored: emits events, no git
      _event_log.py               # NEW — shared event emitter
      _otel_emit.py               # NEW — shared OTel emitter
      _honcho_conclude.py         # NEW — shared dialectic recorder
    hooks/
      pre_tool_call.sh            # existing
      audit_emit.py               # NEW — audit log emitter
      otel_emit.py                # NEW — trace emitter
    iris-config/
      profiles/                   # NEW — per-profile config
        persona/
          SOUL.md
          config.template.yaml
        researcher/
          ...
        coder/
          ...
        ops/
          ...
      skills.yaml                 # promoted from skills.json
      cron.yaml                   # existing
      mcp.yaml                    # existing
      pipelines.yaml              # NEW — declarative pipelines
      guardrails.yaml             # NEW — per-tenant guardrail policies

  litellm/                        # existing
  honcho/                         # existing

  observability/                  # NEW
    compose.yaml                  # OTel + Loki + Promtail + Grafana
    otel-config.yaml
    promtail-config.yaml
    grafana/
      provisioning/
        datasources.yaml
        dashboards.yaml
      dashboards/
        fleet-overview.json
        agent-detail.json
        audit-search.json
        compliance-access.json
        compliance-egress.json
        compliance-privilege.json

  iris-curator/                   # NEW
    compose.yaml
    Dockerfile
    run.py                        # main batch loop
    diff_writer.py                # produces manifest diffs
    pr_open.py                    # opens GitHub PR
    prompts/
      distill.txt                 # the LLM prompt for the curation pass

  iris-dispatcher/                # NEW
    compose.yaml
    Dockerfile
    main.py                       # the dispatcher API
    runtimes/
      daytona.py
      e2b.py
      gvisor.py

  iris-supervisor/                # NEW (corporate mode)
    compose.yaml
    Dockerfile
    main.py                       # fleet supervisor: routes input, enforces tenants

  audit/                          # NEW
    compose.yaml                  # audit-db Postgres
    schema.sql

  scripts/
    setup-secrets.sh              # existing
    mint-iris-key.sh              # existing — kept for V1 compat
    v2-init-profiles.sh           # NEW
    v2-mint-keys.sh               # NEW — per-profile virtual keys
    v2-migrate-from-v1.sh         # NEW — migrates V1 state into V2 event log + manifests
    install-iris-hooks.sh         # existing — kept for V1 compat
    iris-pre-commit-guard.sh      # existing
    iris-commit-msg-guard.sh      # existing

  k8s/                            # NEW (corporate mode)
    base/
    overlays/

  iris-events.db                  # event log (one per profile in personal mode; one shared in corporate K8s)
                                  # actual location is /opt/data/iris-events.db inside containers

  Makefile                        # gains v2 targets
```

### Environment variables (V2 additions)

```bash
# Observability
OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4317
OTEL_SERVICE_NAME_PERSONA=iris-persona
OTEL_SERVICE_NAME_RESEARCHER=iris-researcher
# ... per profile
LOKI_URL=http://loki:3100

# Per-profile virtual keys
IRIS_VIRTUAL_KEY_PERSONA=sk-...
IRIS_VIRTUAL_KEY_RESEARCHER=sk-...
IRIS_VIRTUAL_KEY_CODER=sk-...
IRIS_VIRTUAL_KEY_OPS=sk-...

# Curator
CURATOR_CADENCE="0 4 * * *"
GH_TOKEN=...                      # for opening PRs

# Sandbox dispatcher
SANDBOX_RUNTIME=daytona           # or e2b | gvisor
DAYTONA_API_KEY=...
SANDBOX_POOL_MIN=2
SANDBOX_POOL_MAX=20

# Audit log
AUDIT_DB_PASSWORD=...
AUDIT_DB_URL=postgresql://audit:...@audit-db:5432/audit
AUDIT_RETENTION_DAYS=90           # 2555 for HIPAA

# Multi-tenant
OIDC_ISSUER_URL=https://auth.example.com/realms/iris
OIDC_CLIENT_ID=iris-fleet
OIDC_CLIENT_SECRET=...
VAULT_ADDR=http://vault:8200
VAULT_ROOT_TOKEN=...

# Per-profile messaging
TELEGRAM_BOT_TOKEN_PERSONA=...
TELEGRAM_BOT_TOKEN_RESEARCHER=...
TELEGRAM_BOT_TOKEN_CODER=...
TELEGRAM_BOT_TOKEN_OPS=...
```

### Network topology

```
frontend (bridge, host-loopback access for dashboards)
  ├─ iris-{persona,researcher,coder,ops}      (gateways)
  ├─ iris-dashboard
  ├─ iris-supervisor (corporate)
  ├─ litellm
  ├─ prometheus
  ├─ grafana
  ├─ mission-control
  ├─ oidc-proxy (corporate)
  └─ presidio-{analyzer,anonymizer}

backend (bridge, internal only)
  ├─ iris-curator
  ├─ iris-dispatcher
  ├─ otel-collector
  ├─ loki, promtail
  ├─ honcho-{api,deriver}
  ├─ vault (corporate)
  └─ all gateways here too (for service-to-service)

data (bridge, internal only — no host or LAN access)
  ├─ litellm-db
  ├─ honcho-db, honcho-redis
  └─ audit-db
```

### Volume layout

```
data_persona, data_researcher, data_coder, data_ops    # per-profile Hermes state
shared_kanban                                          # cross-profile task board
loki_data, prometheus_data, grafana_data               # observability
audit_postgres_data                                    # audit log Postgres
honcho_pgdata                                          # Honcho semantic memory
litellm_postgres_data                                  # LiteLLM virtual keys + audit
claude_creds                                           # mounted from host (`~/.iris-backup/.credentials.json:...:ro`) so down -v doesn't wipe OAuth
vault_data (corporate)                                 # Vault secrets
```

The Claude credentials volume changes from a named volume to a host bind-mount in V2 — survives `down -v`.

### Makefile targets (V2)

```makefile
make dev-v2                     # bring up V2 stack (5 planes)
make rebuild-v2                 # rebuild all V2 images
make down-v2                    # stop, preserve volumes
make clean-v2                   # stop + drop volumes (DESTRUCTIVE — confirmation required)
make backup-v2                  # snapshot all volumes + audit log + event log
make restore-v2 BACKUP=...      # restore from snapshot
make migrate-v1                 # one-shot migration from V1 to V2
make fleet-status               # quick CLI fleet view (Mission Control headless)
make audit-query Q="..."        # quick audit log query
make curator-once               # force a single curator run
```

---

## 12. Migration from V1

**Goal:** zero data loss, zero downtime if possible. Run V2 alongside V1 first, cut over once verified.

### 12.1 Pre-migration backup

```bash
make backup           # V1 backup script — Hermes state + LiteLLM DB + Honcho DB
cp -r .git ~/.iris-backup/git-snapshot
cp .env  ~/.iris-backup/env-snapshot
cp litellm/.env ~/.iris-backup/litellm-env-snapshot
```

### 12.2 V1 → V2 event log import

The V2 event log starts populated with V1's git history:

```bash
bash scripts/v2-migrate-from-v1.sh
```

Behind the scenes:

1. Read all `iris-self/*` branches and their commits.
2. For each, parse the commit message + diff to reconstruct the action.
3. Append a row to the new `iris-events.db` with `actor='v1-migration'`, original `ts` from commit date.
4. Read each manifest (cron.yaml, skills.json, mcp.yaml, iris-learned/*.txt) on `main`.
5. Write the current state into V2's manifest layer at `iris-config/`.

After this, the event log has a complete history starting from your earliest V1 work.

### 12.3 Cutover

```bash
# 1. Bring up V2 alongside V1 (different ports for testing)
docker compose -f compose.yaml -f V2/compose.yaml up -d

# 2. Verify V2 dashboards, profiles, observability
# (Spend a day or two driving Iris through V2 paths)

# 3. Once happy, retire V1
docker compose down                           # V1 down
mv compose.yaml compose.v1-archive.yaml
ln -s V2/compose.yaml compose.yaml
docker compose up -d                          # V2 takes over
```

### 12.4 Post-migration validation

```bash
# 1. Event log has full history
sqlite3 /opt/data/iris-events.db "SELECT COUNT(*) FROM events WHERE actor='v1-migration'"

# 2. All V1 capabilities reproducible from V2 manifest
make curator-once
# Should produce zero diffs (V2 manifest matches V1 main)

# 3. All previous iris-self/* branches archived (not deleted)
git for-each-ref refs/heads/iris-self-archive
# Should show 1 branch per pre-existing iris-self/*
```

---

## 13. Troubleshooting

### Plane 1 — Observability

| Symptom | Cause | Fix |
|---|---|---|
| Grafana shows no traces | OTel collector not receiving | Check `OTEL_EXPORTER_OTLP_ENDPOINT` in wrappers; verify collector is healthy |
| Loki search returns nothing | Promtail not collecting | Check Promtail's docker-socket bind mount; verify container labels |
| Dashboards show "No data" | Prometheus not scraping target | Check `prometheus.yml` scrape configs; verify `/metrics` endpoints |

### Plane 2 — Fleet

| Symptom | Cause | Fix |
|---|---|---|
| Profile gateways won't start | Per-profile virtual keys missing | Run `bash scripts/v2-mint-keys.sh <profile>` |
| MCP serve mode connection refused | Profile gateway didn't start mcp serve | Check command in compose; should run `hermes mcp serve` in background |
| Cross-profile MCP call fails | mcp.yaml entries point to wrong hostnames | Use container names (`iris-researcher`), not localhost |

### Plane 3 — Hermes layers

| Symptom | Cause | Fix |
|---|---|---|
| Curator never fires | Cron entry not registered | Check `hermes cron list` per profile; run `iris-cron add` again |
| Honcho dialectic empty | Failure handlers not calling `_honcho_conclude.py` | grep wrappers for the call; verify Honcho API reachable from gateway |
| Periodic nudge doesn't fire | Disabled in profile config | Edit profile's `config.yaml`, set `periodic_nudge.enabled: true` |

### Plane 4 — Governance

| Symptom | Cause | Fix |
|---|---|---|
| Curator PR is empty | No new events since last cycle | Expected if nothing changed; check `events` table |
| Curator PR is huge / unfocused | LLM prompt needs tightening | Edit `iris-curator/prompts/distill.txt` |
| Reconciler doesn't apply manifest | Watcher not running | `docker compose logs iris-reconciler --tail 50` |

### Plane 5 — Substrate

| Symptom | Cause | Fix |
|---|---|---|
| Sandbox spawn timeouts | Pool exhausted | Increase `SANDBOX_POOL_MAX` |
| Egress allowlist blocks legitimate URL | Skill metadata incomplete | Update `skills.yaml` metadata; restart dispatcher |
| Sandbox cost per task is too high | Pool reuse not happening | Check `POOL_MIN`; verify warm sandbox lifetimes |

---

## 14. Security and compliance posture

### Defense in depth (the 5 isolation layers)

| Layer | What's isolated | Mechanism |
|---|---|---|
| Compute | CPU / RAM / syscalls | Per-execution gVisor or microVM (Plane 5) |
| Filesystem | what each agent sees | Per-profile `~/.hermes/profiles/<x>/` + tmpfs scratch + read-only roots |
| Network | what each agent can reach | Egress allowlist per skill / pipeline (Plane 5) + Docker `internal: true` networks |
| Identity | who am I, who is the user | OIDC + JWT scoped to tenant (Plane 7) + Honcho per-peer cards |
| Memory | dialectic insights, embeddings | pgvector schema-per-tenant (Plane 7) + Honcho conclusion ACLs |

### Compliance frame

| Concern | Mechanism |
|---|---|
| SOC2 — audit trail | Audit log Postgres, append-only, 3-year retention |
| SOC2 — access control | OIDC + RBAC tiers (Owner / Admin / User / Guest) |
| HIPAA — PHI in transit | Presidio guardrails on every cloud call |
| HIPAA — PHI at rest | pgvector encrypted-at-rest (cloud-managed); Vault for keys |
| HIPAA — audit retention | 7-year audit log retention via `AUDIT_RETENTION_DAYS` |
| GDPR — right to erasure | Honcho `peer_id` deletion cascades to dialectic + audit redaction |
| GDPR — data residency | Per-tenant pgvector pinned to a region; OpenRouter routing pinned via LiteLLM |

### Threat model: what can a compromised skill do?

Without V2: read all of `/opt/data`, exfiltrate to any URL, pollute the venv permanently.

With V2:
- **Read scope**: only its own sandbox's `/workspace`, plus ambient context Hermes injects.
- **Egress scope**: only domains in the skill's declared allowlist.
- **Persistence**: zero — sandbox dies on task completion.
- **Detection**: every skill action emits to event log + audit log; Curator surfaces anomalies in next batch PR.
- **Containment**: blast radius = one task. Cannot affect orchestrator, cannot affect other agents, cannot affect other tenants.

---

## 15. Future enhancements (V2.5+)

These are out of scope for V2 but worth noting:

- **DSPy + GEPA self-evolution** ([NousResearch/hermes-agent-self-evolution](https://github.com/NousResearch/hermes-agent-self-evolution)). Run evolutionary optimization over the event log to produce measurably better skills. Requires consistent eval corpus.
- **Fine-tuned local fallback model.** Train a small LoRA on the event log so even cloud-key revocation doesn't strand the agent.
- **Federated learning across tenants** (with explicit opt-in). Aggregate failure-memory patterns without sharing raw data. Requires DP machinery.
- **Voice channel.** Whisper STT + Telegram voice + tts → one-tap voice mode.
- **Mobile-first dashboard.** Mission Control mobile app.

---

## 16. Reading list

The architectural primitives V2 builds on, with citations:

- [OpenHands V1 SDK — event-sourced agent state (MLSys 2026)](https://arxiv.org/html/2511.03690v2)
- [Curator — Hermes Agent Docs](https://hermes-agent.nousresearch.com/docs/user-guide/features/curator)
- [Honcho dialectic memory — Hermes integration](https://docs.honcho.dev/v3/guides/integrations/hermes)
- [Profiles: Running Multiple Agents — Hermes](https://hermes-agent.nousresearch.com/docs/user-guide/profiles)
- [Subagent Delegation — Hermes](https://hermes-agent.nousresearch.com/docs/user-guide/features/delegation)
- [Skills System — Hermes](https://hermes-agent.nousresearch.com/docs/user-guide/features/skills)
- [Spring AI Agent Skills — modular discoverable capabilities](https://spring.io/blog/2026/01/13/spring-ai-generic-agent-skills/)
- [Claude Agent Skills — startup-loaded metadata pattern](https://platform.claude.com/docs/en/agents-and-tools/agent-skills/overview)
- [AWS Agent Registry — centralized agent discovery (April 2026)](https://aws.amazon.com/blogs/machine-learning/the-future-of-managing-agents-at-scale-aws-agent-registry-now-in-preview/)
- [Running Agents on Kubernetes with Agent Sandbox (March 2026)](https://kubernetes.io/blog/2026/03/20/running-agents-on-kubernetes-with-agent-sandbox/)
- [Multi-Tenant AI Infrastructure: 5 Isolation Layers](https://isuruig.medium.com/multi-tenant-ai-infrastructure-the-5-isolation-layers-that-determine-whether-your-customers-data-340aaeef4922)
- [Daytona vs E2B — sandbox runtime comparison](https://northflank.com/blog/daytona-vs-e2b-ai-code-execution-sandboxes)
- [Mission Control — open-source agent fleet operator UI](https://github.com/openagentplatform/mission-control)
- [ArgoCD MCP Server — GitOps for AI agents](https://smartstackdev.com/argocd-mcp-server-complete-guide-to-ai-driven-gitops-automation-2026/)
- [Skilldex — package manager for agent skills (arXiv)](https://arxiv.org/abs/2604.16911)

---

## 17. Implementation order — recommended

This is the minimum-cognitive-load path:

1. **Phase 1 first (3 days).** Observability is foundation; everything else relies on it for verification.
2. **Phase 2 next (5 days).** Self-learning loop pays off immediately — Iris's discovery cost drops drastically once Honcho dialectic is wired.
3. **Phase 3 (5 days).** Curator + event log — the GitHub flow problem dissolves here.
4. **Phase 4 (5 days).** Multi-profile fleet — your personal team. Workshop demo material.
5. **Phase 5 (10 days).** Sandbox dispatch — the security upgrade. Workshop's "5 isolation layers" demo.
6. **Phase 6 (10 days).** Mission Control + audit log — operator cockpit. Workshop's compliance module.
7. **Phase 7 (15 days).** Multi-tenant — corporate-grade reference architecture. Workshop's capstone.

Total: ~50 working days for the full V2. Phases 1-4 alone (~18 days) deliver the personal-use win and remove the GitHub-flow pain. Phases 5-7 are the corporate teaching content.

After phase 4 you have a fully working personal Iris fleet with proper observability and self-learning. After phase 7 you have a workshop-grade reference architecture.

---

*— end of V2_INSTALL.md*
