#!/opt/hermes/.venv/bin/python
"""Append one row to the iris event log.

Every iris-* wrapper, every Hermes hook, every curator decision emits one
row. Sub-millisecond latency. No review gate. The file is the source of
truth for audit + curator input + introspection (Phase 6 audit log derives
from this).

Schema — see _event_log_init.sql. Highlights: profile/tenant for multi-
tenancy (Phase 7), actor for "who did this", category+action+subject for
what, outcome for did-it-work, trace_id for cross-service correlation.

Usage from bash:
    _event_log --category package --action install --subject python:httpx \\
               --outcome ok [--cost-usd 0.01] [--trace-id abc123] \\
               [--payload-key foo=bar] [--payload-key baz=qux]

The --payload-key form merges into a single JSON object stored in
payload. Use it for the unstructured stuff that doesn't fit the indexed
columns (reasoning, free-text reasons, parsed Hermes output, etc.).

Failures are swallowed: telemetry must never break the wrapper.
"""
from __future__ import annotations

import argparse
import json
import os
import sqlite3
import sys
from pathlib import Path

DB_PATH = Path(os.environ.get("IRIS_EVENT_LOG", "/opt/data/iris-events.db"))
SCHEMA = Path(os.environ.get("IRIS_EVENT_LOG_SCHEMA", "/usr/local/bin/_event_log_init.sql"))


def _ensure_schema(con: sqlite3.Connection) -> None:
    """Apply the init SQL idempotently. Cheap — CREATE IF NOT EXISTS."""
    if not SCHEMA.exists():
        # Embedded fallback — schema file missing means we're in a test
        # environment. Do the minimum to keep the wrapper working.
        con.executescript(
            """
            CREATE TABLE IF NOT EXISTS events (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              ts TEXT DEFAULT CURRENT_TIMESTAMP,
              profile TEXT DEFAULT 'default',
              tenant TEXT,
              actor TEXT DEFAULT 'iris',
              category TEXT NOT NULL,
              action TEXT NOT NULL,
              subject TEXT,
              payload TEXT,
              outcome TEXT DEFAULT 'ok',
              trace_id TEXT,
              cost_usd REAL,
              tokens_in INTEGER,
              tokens_out INTEGER
            );
            """
        )
        return
    con.executescript(SCHEMA.read_text())


def _parse_payload(pairs: list[str]) -> str | None:
    """Merge --payload-key foo=bar pairs into a single JSON object string."""
    if not pairs:
        return None
    obj: dict = {}
    for p in pairs:
        if "=" not in p:
            continue
        k, v = p.split("=", 1)
        obj[k.strip()] = v.strip()
    return json.dumps(obj) if obj else None


def emit(args: argparse.Namespace) -> int:
    """Write one row. Sub-millisecond latency in WAL mode."""
    DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    # isolation_level=None → autocommit; WAL handles durability.
    # timeout=10s gives us room if multiple writers contend.
    con = sqlite3.connect(str(DB_PATH), isolation_level=None, timeout=10)
    try:
        _ensure_schema(con)
        con.execute(
            """
            INSERT INTO events
              (profile, tenant, actor, category, action, subject, payload,
               outcome, trace_id, cost_usd, tokens_in, tokens_out)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
            """,
            (
                os.environ.get("HERMES_PROFILE", "default"),
                os.environ.get("IRIS_TENANT") or None,
                args.actor,
                args.category,
                args.action,
                args.subject,
                _parse_payload(args.payload_key),
                args.outcome,
                args.trace_id,
                float(args.cost_usd) if args.cost_usd else None,
                int(args.tokens_in) if args.tokens_in else None,
                int(args.tokens_out) if args.tokens_out else None,
            ),
        )
    finally:
        con.close()
    return 0


def main() -> int:
    p = argparse.ArgumentParser(prog="_event_log", description=__doc__)
    p.add_argument("--category", required=True,
                   help="package | skill | cron | mcp | memory | tool_call | mcp_serve | reconcile")
    p.add_argument("--action", required=True,
                   help="install | uninstall | add | remove | invoke | propose | succeed | fail | started")
    p.add_argument("--subject", default=None, help="name/id of what was acted on")
    p.add_argument("--outcome", default="ok", help="ok | error | timeout | cancelled")
    p.add_argument("--actor", default="iris", help="iris | curator | user-<id> | system")
    p.add_argument("--trace-id", default=None, help="correlation id from OTel span")
    p.add_argument("--cost-usd", default=None, help="USD cost of the action, if known")
    p.add_argument("--tokens-in", default=None)
    p.add_argument("--tokens-out", default=None)
    p.add_argument("--payload-key", action="append", default=[],
                   help="key=value pair merged into JSON payload (repeatable)")
    args = p.parse_args()

    try:
        return emit(args)
    except Exception as e:  # noqa: BLE001 — never let telemetry kill the wrapper
        print(f"_event_log: WARNING — {e}", file=sys.stderr)
        return 0


if __name__ == "__main__":
    sys.exit(main())
