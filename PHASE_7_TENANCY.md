# Phase 7 — Multi-Tenant (Corporate Reference Architecture)

**Status:** Architecture document + concrete deltas. Personal-mode deployment
(Phases 1-6) is the substrate this builds on.

## Goal

Hard tenant isolation across all five layers of the stack. After Phase 7,
multiple companies (or multiple departments within a company) can share
the same Iris substrate without any of these failure modes:

- Cross-tenant memory bleed in Honcho's pgvector
- One tenant's runaway loops costing another's quota
- An auditor for tenant A seeing tenant B's logs
- A compromised skill in tenant A reaching tenant B's filesystem
- Tenant A's secrets readable by tenant B's profile gateways

## The 5 isolation layers — concrete mechanism per layer

| Layer | What's isolated | Phase 7 mechanism | Status today |
|---|---|---|---|
| **Compute** | CPU / RAM / syscall surface | Per-execution gVisor or microVM (Phase 5 dispatcher) | Phase 5 doc — opt-in upgrade |
| **Filesystem** | what each agent sees | Per-tenant K8s `PersistentVolume`; tmpfs scratch within sandbox | K8s manifests below |
| **Network** | what each agent can reach | NetworkPolicy per tenant; egress allowlist per skill | NetworkPolicy template below |
| **Identity** | who the user is | OIDC + JWT scoped to tenant; audit_log.actor_id pinned to JWT sub | OIDC requirement below |
| **Memory** | dialectic insights, embeddings | pgvector schema-per-tenant in Honcho | Migration script below |

## Required infrastructure (the corporate deltas)

### 7.1 Identity provider (OIDC)

You need an OIDC issuer reachable by Iris. Options:

- **Keycloak** (self-hosted, open-source) — recommended for on-prem
- **Auth0** / **Okta** (managed) — recommended for cloud
- **AWS Cognito** / **Azure AD B2C** — recommended if you're already on that cloud

JWT claim shape Iris expects:

```json
{
  "sub": "user-12345",
  "tenant": "acme",
  "role": "user",            // owner | admin | user | guest
  "iat": 1700000000,
  "exp": 1700003600
}
```

The `tenant` claim is the load-bearing field — it's what makes everything below tenant-aware.

### 7.2 oauth2-proxy in front of dashboards

```yaml
# corporate/compose.yaml — added to top-level include in corporate mode
services:
  oidc-proxy:
    image: quay.io/oauth2-proxy/oauth2-proxy:v7.6.0
    container_name: oidc-proxy
    restart: unless-stopped
    environment:
      OAUTH2_PROXY_PROVIDER: keycloak-oidc
      OAUTH2_PROXY_CLIENT_ID: iris-fleet
      OAUTH2_PROXY_CLIENT_SECRET: ${OIDC_CLIENT_SECRET}
      OAUTH2_PROXY_OIDC_ISSUER_URL: ${OIDC_ISSUER_URL}
      OAUTH2_PROXY_COOKIE_SECRET: ${OIDC_COOKIE_SECRET}
      OAUTH2_PROXY_UPSTREAMS: |
        http://grafana:3000,
        http://iris-dashboard:9119,
        http://mission-control:8080
      OAUTH2_PROXY_PASS_AUTHORIZATION_HEADER: "true"
      # Add tenant claim from JWT to the upstream request
      OAUTH2_PROXY_SET_AUTHORIZATION_HEADER: "true"
      OAUTH2_PROXY_PASS_USER_HEADERS: "true"
    ports:
      - "127.0.0.1:443:4180"
    networks: [frontend]
```

All host-loopback ports (Grafana 3000, iris-dashboard 9119, mission-control)
move BEHIND the proxy. The proxy enforces login + adds the `Authorization:
Bearer <jwt>` header to every upstream request.

### 7.3 Tenant column propagation

The `tenant` column already exists in:
- `events` table (Phase 3) ✓
- `audit_log` table (Phase 6) ✓

What needs adding:
- Every iris-* wrapper reads `IRIS_TENANT` env (already does — Phase 1) and writes it. Already complete.
- `iris-curator` filters by tenant (`--tenant` flag — added in this commit).
- Per-profile gateway environment in `iris/profiles.compose.yaml` — currently has `IRIS_TENANT: ${IRIS_TENANT:-}` which is empty in personal mode and passed-through in corporate.

### 7.4 Per-tenant Honcho pgvector namespacing

Honcho v3 stores all data in one schema. Multi-tenant requires schema-per-tenant.

```sql
-- Migration script: split-honcho-by-tenant.sql
-- Run once per new tenant; idempotent.

-- For each tenant_id:
DO $$
DECLARE t TEXT := 'acme';
BEGIN
  EXECUTE format('CREATE SCHEMA IF NOT EXISTS tenant_%I', t);
  -- Replicate Honcho's table definitions in the new schema
  EXECUTE format('CREATE TABLE IF NOT EXISTS tenant_%I.peers (LIKE public.peers INCLUDING ALL)', t);
  EXECUTE format('CREATE TABLE IF NOT EXISTS tenant_%I.workspaces (LIKE public.workspaces INCLUDING ALL)', t);
  EXECUTE format('CREATE TABLE IF NOT EXISTS tenant_%I.conclusions (LIKE public.conclusions INCLUDING ALL)', t);
  EXECUTE format('CREATE TABLE IF NOT EXISTS tenant_%I.messages (LIKE public.messages INCLUDING ALL)', t);
  -- ... ditto for sessions, peer_cards, etc. (full Honcho schema)
END $$;
```

The Honcho client must be wrapped to set `search_path = tenant_<tenant>` per
JWT claim. This requires patching honcho-api OR running one Honcho instance
per tenant (simpler operationally; costs more compute).

**Honest path:** for ≤10 tenants, run one honcho-api container per tenant.
For ≥10 tenants, patch the client to switch search_path on JWT.

### 7.5 Vault for secrets

Replace `.env` files with Hashicorp Vault. Each profile gateway becomes:

```yaml
services:
  iris-acme-persona:
    # ...
    environment:
      VAULT_ADDR: http://vault:8200
      VAULT_ROLE_ID: ${VAULT_ROLE_ID_ACME}     # bootstrap secret
    # Vault Agent sidecar populates real secrets from Vault into the container
    # (TELEGRAM_BOT_TOKEN, IRIS_VIRTUAL_KEY, etc.)
```

Concretely: each tenant gets its own Vault path `secret/iris/<tenant>/...`
and a Vault role bound to its JWT. AppRole or Kubernetes auth method are
both acceptable; pick based on your platform.

### 7.6 Network policies (K8s)

```yaml
# k8s/base/network-policy-tenant.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: tenant-isolation
spec:
  podSelector:
    matchLabels:
      tenant: ${TENANT}
  policyTypes: [Ingress, Egress]
  ingress:
    - from:
        # Only same-tenant pods can talk to me
        - podSelector:
            matchLabels:
              tenant: ${TENANT}
        # Plus the shared infra: oidc-proxy, prometheus, otel-collector
        - podSelector:
            matchLabels:
              role: infra
  egress:
    - to:
        - podSelector:
            matchLabels:
              tenant: ${TENANT}
        - podSelector:
            matchLabels:
              role: infra
    # Egress to internet for LLM calls — still goes through LiteLLM
    - to:
        - podSelector:
            matchLabels:
              app: litellm
```

This makes "tenant A's coder gateway cannot send a packet to tenant B's
honcho-api" a hard kernel-level guarantee, not a soft application-level
check.

### 7.7 RBAC tiers

Per Hermes upstream issue [#527](https://github.com/NousResearch/hermes-agent/issues/527),
the four-tier model is:

| Tier | Can | Cannot |
|---|---|---|
| **Owner** | Anything within their tenant + grant admin/user/guest roles | Cross-tenant operations |
| **Admin** | All operations within tenant (manage skills, cron, MCP, secrets) | Change RBAC tiers / tenant boundaries |
| **User** | Use their assigned profiles (chat, view own memory) | See other users' data within tenant |
| **Guest** | Read-only access to assigned profiles | Write any state, see audit log |

Implementation: a small middleware in front of iris-supervisor that decodes
the JWT, looks up the role, and either forwards or rejects with 403.

### 7.8 Audit log retention policies

Phase 6's audit-db schema supports retention. Concrete policies:

| Compliance frame | Retention | Pruning method |
|---|---|---|
| Personal mode | 90 days | Optional cron job DELETE |
| SOC2 | 3 years (1095 days) | Required cron + verified by auditor |
| HIPAA §164.530(j)(2) | 6 years | Required + immutable storage layer (S3 Object Lock) |
| GDPR (right to erasure) | Variable; user-initiated | Special API endpoint with audit trail of erasures |

The retention pruner needs its own role with DELETE on rows past policy:

```sql
CREATE ROLE audit_pruner LOGIN PASSWORD '...';
GRANT SELECT, DELETE ON audit_log TO audit_pruner;
-- Pruner job runs:
DELETE FROM audit_log WHERE ts < NOW() - (current_setting('app.retention_days')::INT || ' days')::INTERVAL;
```

## Migration path: personal → multi-tenant

Order matters. Each step is reversible until the next one starts.

1. **Add tenant column to all reads/writes** (already done in Phases 3+6)
2. **Stand up OIDC issuer** (Keycloak: 1 day)
3. **Add oidc-proxy in front of dashboards** (1 day)
4. **Migrate Vault** (1-2 weeks; depends on existing secret count)
5. **Split Honcho per-tenant** (1 week per 10 tenants if running per-instance; 2-3 weeks if patching client)
6. **Move to K8s with NetworkPolicies** (2-4 weeks; major op shift)
7. **Add audit pruner** (1 day)
8. **Implement RBAC middleware** (1 week)

Total: 1-2 months of platform work, sequenced.

## What's already in place (don't redo)

The following are tenant-ready as of Phase 6:

- ✓ Event log has `tenant` column with index
- ✓ Audit log has `tenant` column with index + append-only enforcement
- ✓ iris-curator filters by `--tenant` and `--profile`
- ✓ Profile gateways carry `IRIS_TENANT` env through to wrappers
- ✓ Wrappers tag every event with the tenant
- ✓ Presidio guardrails work per-tenant (different policies via env)
- ✓ LiteLLM virtual keys can be tagged with tenant for cost attribution
- ✓ OpenTelemetry resource attributes include tenant in spans

The rest is configuration + infrastructure, not code-in-iris-repo work.

## Reference: a real corporate compose

```yaml
# compose.corporate.yaml
name: iris-corporate

include:
  - ./iris/compose.yaml
  - ./litellm/compose.yaml
  - ./honcho/compose.yaml      # one instance per tenant in corp mode
  - ./claude-cli/compose.yaml
  - ./observability/compose.yaml
  - ./audit/compose.yaml
  - ./corporate/oidc-proxy.yaml      # NEW
  - ./corporate/vault.yaml           # NEW
  - ./corporate/mission-control.yaml # NEW
  # Per-tenant profile gateways generated from a Helm/Kustomize template

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

## Reading list

- [Multi-Tenant AI Infrastructure: 5 Isolation Layers](https://isuruig.medium.com/multi-tenant-ai-infrastructure-the-5-isolation-layers-that-determine-whether-your-customers-data-340aaeef4922)
- [The New Multi-Tenant Challenge — Cloud Native Now](https://cloudnativenow.com/contributed-content/the-new-multi-tenant-challenge-securing-ai-agents-in-cloud-native-infrastructure/)
- [MCP Security for Multi-Tenant AI Agents](https://prefactor.tech/blog/mcp-security-multi-tenant-ai-agents-explained)
- [AWS Multi-Tenant Generative AI Reference](https://aws.amazon.com/blogs/machine-learning/build-a-multi-tenant-generative-ai-environment-for-your-enterprise-on-aws/)
- [Hermes RBAC issue #527 — Owner/Admin/User/Guest tiers](https://github.com/NousResearch/hermes-agent/issues/527)
- [Hermes per-tenant memory + audit logging — v0.9/v0.10 roadmap](https://www.remoteopenclaw.com/blog/hermes-development-roadmap-2026)

## When to actually do this

**Don't** stand up Phase 7 prematurely. The personal-mode substrate
(Phases 1-6) is enough for:
- Single operator with multiple specialized profiles (your personal use)
- Small trusted team (≤10 people, mutual trust, single tenant)
- Demo / training environments
- Internal tools where everyone is already authenticated by other means

**Do** stand up Phase 7 when:
- You're billing customers (SaaS)
- You have compliance requirements (SOC2, HIPAA, GDPR)
- You have ≥3 distinct customer organizations
- An auditor will ask "show me tenant A cannot see tenant B"
- You're teaching this in a corporate workshop and need a real reference impl

Each Phase 7 deliverable is independently shippable. Don't try to do all
8 migration steps at once.
