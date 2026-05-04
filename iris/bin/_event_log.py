#!/opt/hermes/.venv/bin/python
"""Append one row to the iris event log.

Storage backend (auto-detected at run time):
  1. Postgres (audit-db, event_log table) when AUDIT_APP_PASSWORD is set.
     Survives container recreate, multi-writer safe, queryable via Grafana.
  2. SQLite WAL fallback at /opt/data/iris-events.db when Postgres is
     unreachable. Same schema shape; the curator falls through to read it.

Why both: starting a fresh stack with `make dev` brings audit-db + iris-
gateway up at the same time. Wrappers may fire before Postgres is ready.
The fallback keeps wrappers working while letting the steady-state path
use the more durable, queryable backend.

Usage from bash:
    _event_log --category package --action install --subject python:httpx \\
               --outcome ok [--cost-usd 0.01] [--trace-id abc123] \\
               [--payload-key foo=bar] [--payload-key baz=qux]

The --payload-key form merges into a single JSON object stored in the
payload column. Use it for unstructured detail that doesn't fit the
indexed columns.

Failures are swallowed: telemetry must never break the wrapper.
"""
from __future__ import annotations

import argparse
import json
import os
import sqlite3
import sys
from pathlib import Path

try:
    import psycopg
except ImportError:
    psycopg = None

# Postgres connection (preferred backend) ----------------------------------
PG_HOST = os.environ.get("AUDIT_DB_HOST", "audit-db")
PG_PORT = os.environ.get("AUDIT_DB_PORT", "5432")
PG_NAME = os.environ.get("AUDIT_DB_NAME", "audit")
PG_USER = os.environ.get("AUDIT_DB_USER", "audit_app")
PG_PASS = os.environ.get("AUDIT_APP_PASSWORD", "")

# SQLite fallback ----------------------------------------------------------
DB_PATH = Path(os.environ.get("IRIS_EVENT_LOG", "/opt/data/iris-events.db"))
SCHEMA = Path(os.environ.get("IRIS_EVENT_LOG_SCHEMA", "/usr/local/bin/_event_log_init.sql"))


def _parse_payload(pairs: list[str]) -> dict:
    obj: dict = {}
    for p in pairs or []:
        if "=" not in p:
            continue
        k, v = p.split("=", 1)
        obj[k.strip()] = v.strip()
    return obj


def _emit_postgres(args: argparse.Namespace, payload_obj: dict) -> bool:
    """Try Postgres backend. Return True on success, False to fall through."""
    if psycopg is None or not PG_PASS:
        return False
    try:
        conn_str = f"postgresql://{PG_USER}:{PG_PASS}@{PG_HOST}:{PG_PORT}/{PG_NAME}"
        with psycopg.connect(conn_str, connect_timeout=2) as conn:
            with conn.cursor() as cur:
                cur.execute(
                    """
                    INSERT INTO event_log
                      (profile, tenant, actor, category, action, subject,
                       payload, outcome, trace_id, cost_usd, tokens_in, tokens_out)
                    VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
                    """,
                    (
                        os.environ.get("HERMES_PROFILE", "default"),
                        os.environ.get("IRIS_TENANT") or None,
                        args.actor,
                        args.category,
                        args.action,
                        args.subject,
                        json.dumps(payload_obj) if payload_obj else None,
                        args.outcome,
                        args.trace_id,
                        float(args.cost_usd) if args.cost_usd else None,
                        int(args.tokens_in) if args.tokens_in else None,
                        int(args.tokens_out) if args.tokens_out else None,
                    ),
                )
            conn.commit()
        return True
    except Exception:  # noqa: BLE001 — fall through to SQLite
        return False


def _ensure_sqlite_schema(con: sqlite3.Connection) -> None:
    if SCHEMA.exists():
        con.executescript(SCHEMA.read_text())
        return
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


def _emit_sqlite(args: argparse.Namespace, payload_obj: dict) -> None:
    DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    con = sqlite3.connect(str(DB_PATH), isolation_level=None, timeout=10)
    try:
        _ensure_sqlite_schema(con)
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
                json.dumps(payload_obj) if payload_obj else None,
                args.outcome,
                args.trace_id,
                float(args.cost_usd) if args.cost_usd else None,
                int(args.tokens_in) if args.tokens_in else None,
                int(args.tokens_out) if args.tokens_out else None,
            ),
        )
    finally:
        con.close()


def emit(args: argparse.Namespace) -> int:
    payload_obj = _parse_payload(args.payload_key)
    if _emit_postgres(args, payload_obj):
        return 0
    # Postgres unreachable — fall back to SQLite. The next curator run
    # will read both stores transparently (curator handles fallback too).
    _emit_sqlite(args, payload_obj)
    return 0


def main() -> int:
    p = argparse.ArgumentParser(prog="_event_log", description=__doc__)
    p.add_argument("--category", required=True)
    p.add_argument("--action", required=True)
    p.add_argument("--subject", default=None)
    p.add_argument("--outcome", default="ok")
    p.add_argument("--actor", default="iris")
    p.add_argument("--trace-id", default=None)
    p.add_argument("--cost-usd", default=None)
    p.add_argument("--tokens-in", default=None)
    p.add_argument("--tokens-out", default=None)
    p.add_argument("--payload-key", action="append", default=[])
    args = p.parse_args()

    try:
        return emit(args)
    except Exception as e:  # noqa: BLE001
        print(f"_event_log: WARNING — {e}", file=sys.stderr)
        return 0


if __name__ == "__main__":
    sys.exit(main())
