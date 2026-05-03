-- Iris event log — append-only WAL of every action Iris (or her wrappers,
-- or the curator) takes. Single source of truth for audit + curator input
-- + introspection.
--
-- Per OpenHands V1 (MLSys 2026): event sourcing has negligible overhead and
-- enables reliable session recovery. Per the community SQLite event-store
-- pattern, schema is keyed by id with timestamp + categorical columns +
-- structured payload.
--
-- Idempotent: runs on every boot. CREATE IF NOT EXISTS — never drops data.

PRAGMA journal_mode = WAL;
PRAGMA synchronous = NORMAL;     -- WAL-safe; durable across crashes, faster than FULL
PRAGMA temp_store = MEMORY;

CREATE TABLE IF NOT EXISTS events (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  ts          TEXT    NOT NULL DEFAULT CURRENT_TIMESTAMP,
  profile     TEXT    NOT NULL DEFAULT 'default',
  tenant      TEXT,                          -- NULL in personal mode; set in Phase 7
  actor       TEXT    NOT NULL DEFAULT 'iris',  -- iris | curator | user-id | system
  category    TEXT    NOT NULL,              -- skill | cron | mcp | package | memory | tool_call | mcp_serve | reconcile
  action      TEXT    NOT NULL,              -- install | uninstall | add | remove | invoke | propose | succeed | fail
  subject     TEXT,                          -- the name/id of what was acted on
  payload     TEXT,                          -- JSON, full structured detail
  outcome     TEXT    NOT NULL DEFAULT 'ok', -- ok | error | timeout | cancelled
  trace_id    TEXT,                          -- correlation across services
  cost_usd    REAL,                          -- per-call cost where known
  tokens_in   INTEGER,
  tokens_out  INTEGER
);

-- Hot-path indexes. The curator's nightly distill query joins on
-- (ts > last_cycle, category, outcome). Audit queries scan by actor + ts.
-- A trace_id index makes Grafana → event-log drill-down instant.
CREATE INDEX IF NOT EXISTS events_ts          ON events(ts);
CREATE INDEX IF NOT EXISTS events_actor_ts    ON events(actor, ts);
CREATE INDEX IF NOT EXISTS events_category_ts ON events(category, ts);
CREATE INDEX IF NOT EXISTS events_outcome_ts  ON events(outcome, ts);
CREATE INDEX IF NOT EXISTS events_trace       ON events(trace_id);
CREATE INDEX IF NOT EXISTS events_tenant_ts   ON events(tenant, ts);

-- Sentinel — tells callers "schema is up". Inserted only on first run; the
-- INSERT is wrapped in WHERE NOT EXISTS so it's safe on re-init.
INSERT INTO events (category, action, subject, outcome, payload)
SELECT 'reconcile', 'init', 'event_log_schema',
       'ok', json_object('version', 'v2.phase3', 'ts', CURRENT_TIMESTAMP)
WHERE NOT EXISTS (SELECT 1 FROM events WHERE category='reconcile' AND action='init');
