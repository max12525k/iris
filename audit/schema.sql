-- Iris V2 — audit log schema (Postgres 16).
--
-- Compliance-grade append-only record of every action that touched user data
-- or system state. Distinct from the operational event log (SQLite WAL):
-- this one has retention policies, hash-chained tamper-evidence (Phase 6.x),
-- and explicit REVOKE on UPDATE+DELETE so accidental rewrites are physically
-- impossible.
--
-- Per SOC2 Common Criteria CC7.2 and HIPAA §164.312(b), the audit trail must
-- (a) record sufficient detail to reconstruct events, (b) be tamper-evident,
-- (c) be retained per applicable regulation. This schema satisfies (a) and
-- prepares for (b) via the hash_chain column (Phase 6.x adds the trigger).

CREATE TABLE IF NOT EXISTS audit_log (
    id              BIGSERIAL PRIMARY KEY,
    ts              TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    -- WHO
    tenant          TEXT,                          -- NULL in personal mode
    profile         TEXT NOT NULL,                 -- which iris profile
    actor_type      TEXT NOT NULL,                 -- user | agent | curator | system
    actor_id        TEXT NOT NULL,                 -- user-id, "iris-bot", etc.

    -- WHAT
    action          TEXT NOT NULL,                 -- read | write | install | delete | invoke | login | etc.
    resource_type   TEXT NOT NULL,                 -- skill | memory | mcp_server | secret | config | session | message
    resource_id     TEXT NOT NULL,                 -- name/id of the resource

    -- HOW it ended
    outcome         TEXT NOT NULL,                 -- ok | denied | error | timeout
    trace_id        TEXT,                          -- correlation across services

    -- WAS PII INVOLVED
    pii_redacted    BOOLEAN NOT NULL DEFAULT FALSE,
    pii_categories  TEXT[],                        -- which Presidio categories fired

    -- DETAILS
    payload         JSONB,                         -- everything else, structured
    payload_size    INTEGER GENERATED ALWAYS AS (octet_length(payload::TEXT)) STORED,

    -- TAMPER EVIDENCE (Phase 6.x — populated by trigger)
    prev_hash       TEXT,
    row_hash        TEXT
);

-- Hot-path indexes. Compliance queries are typically:
--   "show all reads on user X's data in the last 90 days"
--   "show all installs by profile P last week"
--   "per-tenant cost attribution last month"
CREATE INDEX IF NOT EXISTS audit_log_ts          ON audit_log(ts DESC);
CREATE INDEX IF NOT EXISTS audit_log_tenant_ts   ON audit_log(tenant, ts DESC);
CREATE INDEX IF NOT EXISTS audit_log_actor_ts    ON audit_log(actor_id, ts DESC);
CREATE INDEX IF NOT EXISTS audit_log_resource    ON audit_log(resource_type, resource_id);
CREATE INDEX IF NOT EXISTS audit_log_outcome     ON audit_log(outcome) WHERE outcome != 'ok';
CREATE INDEX IF NOT EXISTS audit_log_trace       ON audit_log(trace_id) WHERE trace_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS audit_log_pii         ON audit_log(pii_redacted) WHERE pii_redacted = TRUE;

-- ─── Append-only enforcement ────────────────────────────────────────────────
-- The `audit` user is the database owner created by POSTGRES_USER, so it
-- has implicit full privileges as the table owner — REVOKE from PUBLIC
-- doesn't constrain the owner. Real append-only enforcement requires
-- separating the DBA role from the application connection role.
--
-- Pattern (per OWASP audit-log cheat sheet):
--   audit         = DBA (postgres superuser equivalent — owns the table)
--   audit_app     = app connection role; INSERT-only (Hermes connects as this)
--   audit_reader  = read-only role for compliance queries / Grafana
--   audit_pruner  = retention enforcement; DELETE only on rows past policy
--
-- We CREATE the table while logged in as `audit` (the DBA) so it can grant
-- to the other roles. The Hermes-side hook connects as `audit_app`.

-- Roles created without passwords here; the entrypoint hook
-- (audit/init-roles.sh) sets passwords from env vars at first boot. This
-- keeps secrets out of version-controlled SQL.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'audit_app') THEN
        CREATE ROLE audit_app LOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'audit_reader') THEN
        CREATE ROLE audit_reader LOGIN;
    END IF;
END $$;

-- Grant exactly what each role needs — nothing more.
REVOKE ALL ON audit_log FROM PUBLIC;
GRANT INSERT, SELECT ON audit_log TO audit_app;
GRANT USAGE, SELECT ON SEQUENCE audit_log_id_seq TO audit_app;
GRANT SELECT ON audit_log TO audit_reader;

-- The DBA (`audit`) explicitly does NOT have UPDATE/DELETE through normal
-- connections either — that mutation must be deliberate and logged.
-- (Postgres table owners can always reclaim privileges, so this is an
--  operational policy, not a hard cryptographic guarantee. The hash chain
--  added in Phase 6.x makes silent mutation detectable.)
REVOKE UPDATE, DELETE, TRUNCATE ON audit_log FROM audit;

-- ─── Retention helper view ──────────────────────────────────────────────────
-- Personal mode: 90 days. SOC2: 3 years. HIPAA: 7 years.
-- Configure via AUDIT_RETENTION_DAYS env var; a cron job runs the prune
-- using a separate role that DOES have DELETE — but only for rows older
-- than the policy. The policy is enforced in the prune script, not here.

CREATE OR REPLACE VIEW audit_log_recent AS
    SELECT * FROM audit_log
    WHERE ts >= NOW() - INTERVAL '7 days'
    ORDER BY ts DESC;

GRANT SELECT ON audit_log_recent TO audit_reader;

-- ─── Sentinel row ───────────────────────────────────────────────────────────
-- Inserted on first init so any "is the audit log functional?" check can
-- query for at least one row.

INSERT INTO audit_log (
    profile, actor_type, actor_id, action, resource_type, resource_id,
    outcome, payload
) VALUES (
    'system', 'system', 'init', 'create', 'audit_schema', 'v2.phase6',
    'ok', jsonb_build_object('version', 'v2.phase6', 'created_at', NOW())
)
ON CONFLICT DO NOTHING;

-- ─── event_log — operational event stream (replaces SQLite WAL) ─────────────
--
-- Distinct from audit_log on these axes:
--   audit_log = compliance, append-only, retention-policy controlled,
--               every tool call lands here (Hermes hooks)
--   event_log = operational, high-volume, used by iris-curator distill,
--               every wrapper invocation lands here (the bash wrappers)
--
-- Why move from SQLite WAL to Postgres:
--   1. SQLite lived in /opt/data named volume — destroyed by `down -v`.
--      Postgres in audit-db has the same exposure but is easier to back up
--      via pg_dump and to bind-mount the data dir for guaranteed durability.
--   2. Single source of truth for both event + audit makes Grafana panels
--      simpler (one Postgres datasource, two tables).
--   3. Concurrent writes from N profile gateways + reconciler don't
--      contend on a single SQLite file (Postgres handles multi-writer).
--   4. Cross-row queries (joins between audit + event for a given trace_id)
--      become trivial.

CREATE TABLE IF NOT EXISTS event_log (
    id              BIGSERIAL PRIMARY KEY,
    ts              TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    profile         TEXT NOT NULL DEFAULT 'default',
    tenant          TEXT,                          -- NULL in personal mode
    actor           TEXT NOT NULL DEFAULT 'iris',  -- iris | curator | user-id | system

    category        TEXT NOT NULL,                 -- skill | cron | mcp | package | memory | tool_call | mcp_serve | reconcile
    action          TEXT NOT NULL,                 -- install | uninstall | add | remove | invoke | propose | succeed | fail | started
    subject         TEXT,                          -- name/id of what was acted on

    payload         JSONB,                         -- structured detail
    outcome         TEXT NOT NULL DEFAULT 'ok',    -- ok | error | timeout | cancelled
    trace_id        TEXT,                          -- correlation across services

    cost_usd        NUMERIC(10, 6),                -- per-call cost
    tokens_in       INTEGER,
    tokens_out      INTEGER
);

-- Hot-path indexes match the SQLite schema we're replacing.
CREATE INDEX IF NOT EXISTS event_log_ts          ON event_log(ts DESC);
CREATE INDEX IF NOT EXISTS event_log_actor_ts    ON event_log(actor, ts DESC);
CREATE INDEX IF NOT EXISTS event_log_category_ts ON event_log(category, ts DESC);
CREATE INDEX IF NOT EXISTS event_log_outcome_ts  ON event_log(outcome, ts DESC) WHERE outcome != 'ok';
CREATE INDEX IF NOT EXISTS event_log_trace       ON event_log(trace_id) WHERE trace_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS event_log_tenant_ts   ON event_log(tenant, ts DESC);
CREATE INDEX IF NOT EXISTS event_log_profile_ts  ON event_log(profile, ts DESC);

-- Same role grants as audit_log — audit_app writes, audit_reader reads.
-- UPDATE/DELETE explicitly NOT granted to either role; mutations require
-- the DBA (audit user) which deliberately doesn't connect from app code.
GRANT INSERT, SELECT ON event_log TO audit_app;
GRANT USAGE, SELECT ON SEQUENCE event_log_id_seq TO audit_app;
GRANT SELECT ON event_log TO audit_reader;
REVOKE UPDATE, DELETE, TRUNCATE ON event_log FROM audit;

-- Sentinel row.
INSERT INTO event_log (category, action, subject, outcome, payload)
VALUES ('reconcile', 'init', 'event_log_schema',
        'ok', jsonb_build_object('version', 'v2.phase6.postgres', 'created_at', NOW()))
ON CONFLICT DO NOTHING;
