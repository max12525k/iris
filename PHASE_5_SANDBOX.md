# Phase 5 — Sandbox Dispatch (Design Doc)

**Status:** Architectural design + decision tree. **Implementation deferred** to a follow-up cycle, by design — see "Why this is a doc, not code" below.

## Goal

Per-execution isolation. Tool calls, skills, cron job bodies, and package
installs all run in fresh ephemeral sandboxes. Failed installs cannot break
the orchestrator. The 5 isolation layers (compute / fs / network / identity /
memory) are physically enforced.

## Why this is a doc, not code

The 2026 community consensus, surfaced in research:

> *"Mounting the Docker socket into containers is identified as a
> misconfiguration that creates straightforward attack paths. Containers
> running with the Docker socket mounted (/var/run/docker.sock) give
> attackers a direct path to the host."*  
> — Multiple sources; see Phase 5 reading list

V1 already mounts `/var/run/docker.sock` into `iris-gateway` for the claude-cli
wrapper. **A docker-in-docker dispatcher stub would amplify this risk** without
adding meaningful isolation. Real Phase 5 implementation requires either:

- **microVM dispatch** (Firecracker / Cloud Hypervisor self-hosted, or via E2B)
- **gVisor user-space kernel** (Modal-style)
- **Daytona** (hardened containers + persistent dev workspaces)
- **Docker Sandboxes** (March 2026 — microVM per agent with private Docker daemon)

All three require either external paid services (E2B, Daytona) or substantial
self-hosted infrastructure (Firecracker on bare metal). Choosing one is a
real architectural decision the user makes at deploy time, not something
that ships as a library default.

## Decision tree

```
Are you running personal-scale (1 user, ≤4 profiles)?
├── Yes
│   ├── Do you accept some risk in exchange for zero new infra?
│   │   ├── Yes  → keep V1 substrate; add Linux namespaces (firejail/unshare)
│   │   │         for the iris-* wrappers' install step. Documented below.
│   │   └── No   → Daytona ($0.067/hr/sandbox, dev-friendly, 27-90ms cold start)
│   └── Are most actions cheap (skills, cron) vs heavy (long-running code)?
│       └── If cheap: Daytona. If heavy: Modal (Python-native, GPU-friendly).
│
└── Corporate-scale (≥10 employees, ≥50 profile gateways)?
    ├── Are you on Kubernetes already?
    │   └── Yes → Agent Sandbox K8s primitive (SIG Apps, March 2026)
    │            + gVisor as the per-pod runtime
    └── Greenfield deployment?
        └── E2B Pro ($150/mo + per-second usage) — Firecracker microVM,
            hardware boundary, the safest option in 2026
```

## Architecture: where the dispatcher fits

```
       ┌─────────────────────────────────────────────────┐
       │  Orchestrator: profile gateway (Hermes)         │
       │  Persistent. Plans + dispatches.                │
       └──────────────┬──────────────────────────────────┘
                      │
                      │ HTTP API (internal)
                      ▼
       ┌─────────────────────────────────────────────────┐
       │  iris-dispatcher (NEW container, Phase 5)       │
       │  Receives: { profile, task_id, image, command,  │
       │              fs_mode, egress, timeout, budget } │
       │  Returns:  { sandbox_id, endpoint, exec_proxy } │
       │                                                  │
       │  Backed by ONE of:                               │
       │   - Daytona API client                           │
       │   - E2B SDK                                      │
       │   - K8s Job creation (Agent Sandbox primitive)   │
       │   - Local Firecracker (advanced; bare metal)     │
       └──────────────┬──────────────────────────────────┘
                      │
                      ▼
       ┌─────────────────────────────────────────────────┐
       │  Per-task sandbox (microVM or gVisor pod)       │
       │  Lifetime: this single task                     │
       │  fs:        tmpfs scratch + /workspace ro       │
       │  network:   egress allowlist per skill          │
       │  identity:  scoped credentials (no host secrets)│
       │  budget:    hard timeout + token budget         │
       └─────────────────────────────────────────────────┘
                      │
                      ▼
                  result + events
                  → flows back to event log
```

## API surface (target shape)

```
POST /v1/sandboxes
  body: {
    profile:          string,   // e.g. "researcher"
    tenant:           string,   // "" in personal mode
    task_id:          string,   // for trace correlation
    runtime:          "python:3.13" | "node:22" | "alpine" | ... ,
    fs_mode:          "ephemeral" | "workspace_ro" | "workspace_rw",
    egress_allowlist: [string],  // domain names; empty = deny-all
    timeout_s:        number,
    budget_usd:       number,
    env:              { K: V },
  }
  returns 201: {
    sandbox_id: string,
    endpoint:   string,  // unix-socket or HTTP for exec
    expires_at: timestamp,
  }

POST /v1/sandboxes/{id}/exec
  body: { cmd: [string], stdin?: string }
  returns 200: { stdout, stderr, exit_code, cost_usd, duration_ms }

DELETE /v1/sandboxes/{id}
  returns 204
```

## Wrapper integration (target shape)

After Phase 5 lands, `iris-learn python httpx` becomes:

```bash
SANDBOX=$(curl -X POST http://iris-dispatcher:8080/v1/sandboxes -d '{
  "profile": "'"$HERMES_PROFILE"'",
  "task_id": "learn-py-httpx-'"$(date +%s)"'",
  "runtime": "python:3.13-slim",
  "fs_mode": "ephemeral",
  "egress_allowlist": ["pypi.org", "files.pythonhosted.org"],
  "timeout_s": 60,
  "budget_usd": 0.05
}' | jq -r .sandbox_id)

curl -X POST http://iris-dispatcher:8080/v1/sandboxes/$SANDBOX/exec -d '{
  "cmd": ["pip", "install", "--target", "/workspace", "httpx"]
}'

# Sandbox dies. If install succeeded, pull artifact to /opt/data/profile-libs/
# Wrapper records event log entry as before.
```

**Failed install in the sandbox cannot affect the orchestrator's venv.** The
existing wrapper structure (event log + manifest commit) doesn't change;
only the install step routes through the dispatcher.

## Per-tenant egress allowlists

Default per-task egress: deny-all. Per-skill or per-pipeline declares the
allowlist via skill metadata:

```yaml
# In iris/iris-config/skills.yaml metadata
- name: blogwatcher-rss
  egress_allowlist:
    - feeds.bloomberg.com
    - rss.cnn.com
    - theverge.com
```

Sandbox dispatcher passes the allowlist to the runtime; the sandbox's
network namespace enforces it. **No exfiltration to attacker-controlled
domains, even if a skill is compromised.**

## Personal-scale fallback: Linux namespaces (lightweight)

If you want SOMETHING better than V1 today without standing up Daytona/E2B,
the cheapest acceptable option is `firejail` per-wrapper invocation:

```bash
# Within iris-learn (and iris-skill install path)
firejail --noprofile \
         --net=none \
         --read-only=/usr \
         --whitelist=/tmp/sandbox-${TASK_ID} \
         --rlimit-as=512m \
         --timeout=00:01:00 \
         -- /opt/hermes/.venv/bin/uv pip install --target /tmp/sandbox-${TASK_ID} "$PKG"
```

This gives you:
- ✓ Filesystem isolation (whitelist-only writes)
- ✓ Network isolation (`--net=none` — no egress; can be relaxed per skill)
- ✓ Memory bounds (`rlimit-as`)
- ✗ NOT compute isolation (still shares the host kernel) — escapes are possible
- ✗ NOT credential isolation (env vars leak unless explicitly stripped)

**Acceptable for personal-mode where the threat model is "broken pip install"
not "malicious skill author."** Not acceptable for corporate / multi-tenant.

To enable this path: add `firejail` to `iris/iris-learned/apt.txt`, rebuild,
and update wrappers to wrap their install command with the firejail invocation
above. ~half day of work; doc-deferred until needed.

## Reading list (validated 2026-current)

- [Why MicroVMs: The Architecture Behind Docker Sandboxes — Docker Blog](https://www.docker.com/blog/why-microvms-the-architecture-behind-docker-sandboxes/)
- [How to sandbox AI agents in 2026: MicroVMs, gVisor & isolation strategies — Northflank](https://northflank.com/blog/how-to-sandbox-ai-agents)
- [AI Agent Sandboxing Explained — Why Docker Is Not Enough — SoftwareSeni](https://www.softwareseni.com/ai-agent-sandboxing-explained-why-docker-is-not-enough-and-what-actually-works/)
- [Container Escape Vulnerabilities: AI Agent Security for 2026 — Blaxel](https://blaxel.ai/blog/container-escape)
- [Your Container Is Not a Sandbox — emirb (microVM 2026 review)](https://emirb.github.io/blog/microvm-2026/)
- [Daytona vs E2B in 2026 — Northflank](https://northflank.com/blog/daytona-vs-e2b-ai-code-execution-sandboxes)
- [Running Agents on Kubernetes with Agent Sandbox (March 2026) — Kubernetes Blog](https://kubernetes.io/blog/2026/03/20/running-agents-on-kubernetes-with-agent-sandbox/)

## Decision the operator makes (next steps)

When you're ready to land Phase 5, choose:

1. **Personal mode, lightest path:** add firejail to iris-learned, wrap install
   commands. ~half day.
2. **Personal mode, proper isolation:** sign up for Daytona, build the
   `iris-dispatcher` service. ~1 week.
3. **Corporate mode:** stand up gVisor on K8s with Agent Sandbox primitive,
   build dispatcher as K8s controller. ~2-3 weeks.
4. **Defer entirely:** treat V1's same-container execution as the threat
   model "I trust the skill authors I install from." Document this risk
   posture explicitly. Zero new code.

The choice depends on your threat model and infra. None of them is wrong;
they're different points on the cost/isolation curve.
