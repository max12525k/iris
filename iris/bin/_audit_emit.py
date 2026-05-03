#!/opt/hermes/.venv/bin/python
"""Append one row to the compliance-grade audit log Postgres.

Distinct from _event_log (fast operational SQLite). The audit log is for
SOC2/HIPAA-grade questions: "who accessed what, when, and what was the
outcome." It's append-only (the audit_app role has INSERT-only privileges)
and uses Postgres for retention-policy management.

Usage from bash (or directly):
    _audit_emit --action invoke --resource-type tool --resource-id terminal \\
                --outcome ok [--actor-type agent] [--actor-id iris-bot] \\
                [--pii-redacted true] [--pii-categories CC,SSN]

Failures are swallowed: telemetry must never break the wrapper.

For Phase 6, this script can be called from any wrapper to dual-write
(event log + audit log). For Phase 6.x, a Hermes post_tool_call hook
will call this script automatically on every tool invocation, removing
the need for explicit wrapper-side calls.
"""
from __future__ import annotations

import argparse
import json
import os
import sys

try:
    import psycopg
except ImportError:
    psycopg = None  # graceful — script becomes a no-op if Postgres lib is missing


def _build_db_url() -> str:
    """Construct the Postgres connection URL from per-component env vars.

    Avoids embedding a default password in source so the pre-commit guard
    doesn't flag the file. Components default to the in-cluster service
    name + standard port; the password MUST come from env (no fallback)."""
    host = os.environ.get("AUDIT_DB_HOST", "audit-db")
    port = os.environ.get("AUDIT_DB_PORT", "5432")
    name = os.environ.get("AUDIT_DB_NAME", "audit")
    user = os.environ.get("AUDIT_DB_USER", "audit_app")
    password = os.environ.get("AUDIT_APP_PASSWORD") or os.environ.get("AUDIT_DB_PASSWORD", "")
    if not password:
        return ""  # _build_db_url returning "" signals "audit log unavailable"
    return f"postgresql://{user}:{password}@{host}:{port}/{name}"


DB_URL = _build_db_url()


def emit(args: argparse.Namespace) -> int:
    if psycopg is None:
        # Dependency not installed — Phase 6 is opt-in. Print a one-time
        # warning so the operator knows and bake-in is missing.
        print(
            "_audit_emit: WARNING — psycopg not installed; audit log row dropped. "
            "Add psycopg[binary] to iris/Dockerfile.iris-bridge to enable Phase 6 emission.",
            file=sys.stderr,
        )
        return 0
    if not DB_URL:
        # No password configured — audit log emission silently disabled.
        # The wrapper still works; the operational event log still fills.
        # Operator opts in by setting AUDIT_APP_PASSWORD.
        return 0

    payload_obj = {}
    for p in args.payload_key or []:
        if "=" in p:
            k, v = p.split("=", 1)
            payload_obj[k.strip()] = v.strip()

    pii_categories = (
        args.pii_categories.split(",") if args.pii_categories else None
    )

    try:
        with psycopg.connect(DB_URL, connect_timeout=5) as conn:
            with conn.cursor() as cur:
                cur.execute(
                    """
                    INSERT INTO audit_log (
                      tenant, profile, actor_type, actor_id,
                      action, resource_type, resource_id,
                      outcome, trace_id,
                      pii_redacted, pii_categories,
                      payload
                    ) VALUES (
                      %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s
                    )
                    """,
                    (
                        os.environ.get("IRIS_TENANT") or None,
                        os.environ.get("HERMES_PROFILE", "default"),
                        args.actor_type,
                        args.actor_id,
                        args.action,
                        args.resource_type,
                        args.resource_id,
                        args.outcome,
                        args.trace_id,
                        args.pii_redacted == "true",
                        pii_categories,
                        json.dumps(payload_obj) if payload_obj else None,
                    ),
                )
            conn.commit()
    except Exception as e:  # noqa: BLE001
        print(f"_audit_emit: WARNING — could not write audit row: {e}", file=sys.stderr)
    return 0


def main() -> int:
    p = argparse.ArgumentParser(prog="_audit_emit", description=__doc__)
    p.add_argument("--action", required=True,
                   help="read | write | install | delete | invoke | login | etc.")
    p.add_argument("--resource-type", required=True,
                   help="skill | memory | mcp_server | secret | config | session | message | tool")
    p.add_argument("--resource-id", required=True,
                   help="name/id of the resource being acted upon")
    p.add_argument("--outcome", default="ok", help="ok | denied | error | timeout")
    p.add_argument("--actor-type", default="agent", help="user | agent | curator | system")
    p.add_argument("--actor-id", default="iris-bot")
    p.add_argument("--trace-id", default=None)
    p.add_argument("--pii-redacted", default="false")
    p.add_argument("--pii-categories", default=None,
                   help="comma-separated Presidio categories that fired")
    p.add_argument("--payload-key", action="append", default=[],
                   help="key=value (repeatable) — additional JSONB context")
    args = p.parse_args()

    try:
        return emit(args)
    except Exception as e:  # noqa: BLE001
        print(f"_audit_emit: WARNING — {e}", file=sys.stderr)
        return 0


if __name__ == "__main__":
    sys.exit(main())
