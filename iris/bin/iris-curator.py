#!/opt/hermes/.venv/bin/python
"""Iris Curator — distill the event log into a markdown summary for human review.

V2.1 — also bundles dirty manifest paths into a single commit / PR per
cadence, replacing the per-action iris-self/* commits the V1 wrappers
used to make. This is the GitOps split V2_INSTALL.md §6 promised:
fast autonomous OBSERVATION (event log) decoupled from slow reviewed
INTENT (manifests, opened as one PR per day).

Reads the event log (Postgres event_log table preferred; SQLite fallback),
groups events since the last cycle by category + outcome, and emits a
markdown file at /repo/iris-curator-pending/distill-YYYY-MM-DD.md.

When --emit-pr is passed AND /repo has dirty manifest paths (iris-learned/,
iris-config/cron.yaml/skills.json/mcp.yaml), the curator:
  1. Creates a branch iris-curator/distill-YYYY-MM-DD-HHMMSS
  2. Stages ONLY the known manifest paths (user WIP elsewhere is untouched)
  3. Commits with the distill markdown as the body
  4. Reports the branch name; user pushes via 'git push' + opens PR

Usage:
    iris-curator              run once for the prior 24h, write distill file
    iris-curator --since 7d   look back 7 days
    iris-curator --print-only don't write file; print to stdout
    iris-curator --emit-pr    write distill + commit dirty manifests on a branch
    iris-curator --status     just print event-log stats and exit
    iris-curator --tenant X   filter to one tenant
    iris-curator --profile Y  filter to one profile

Design properties:
  - No LLM call by default (deterministic distill); --llm flag reserved.
  - Idempotent within the day — re-running just regenerates the markdown.
  - File-based handoff for review — works without GitHub auth.
  - Branch creation respects user WIP — only known manifest paths staged.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import sqlite3
import subprocess
import sys
from collections import Counter, defaultdict
from pathlib import Path

# Manifest paths the curator manages. ONLY these get staged when --emit-pr
# is invoked — anything else in /repo is left untouched (user WIP safety).
MANIFEST_PATHS = [
    "iris/iris-learned",                  # apt.txt, python.txt, npm.txt, rationale.md
    "iris/iris-config/cron.yaml",
    "iris/iris-config/skills.json",
    "iris/iris-config/mcp.yaml",
]
REPO_ROOT = Path(os.environ.get("IRIS_REPO_ROOT", "/repo"))

DB_PATH = Path(os.environ.get("IRIS_EVENT_LOG", "/opt/data/iris-events.db"))
OUT_DIR = Path(os.environ.get("IRIS_CURATOR_OUT", "/repo/iris-curator-pending"))

# Postgres backend (preferred — durable, multi-writer, queryable from Grafana).
PG_HOST = os.environ.get("AUDIT_DB_HOST", "audit-db")
PG_PORT = os.environ.get("AUDIT_DB_PORT", "5432")
PG_NAME = os.environ.get("AUDIT_DB_NAME", "audit")
PG_USER = os.environ.get("AUDIT_DB_USER", "audit_app")
PG_PASS = os.environ.get("AUDIT_APP_PASSWORD", "")

try:
    import psycopg
except ImportError:
    psycopg = None


def _parse_since(spec: str) -> dt.datetime:
    """'24h', '7d', '30m' → datetime in the past."""
    n = int(spec[:-1])
    unit = spec[-1].lower()
    delta = {"m": dt.timedelta(minutes=n),
             "h": dt.timedelta(hours=n),
             "d": dt.timedelta(days=n)}[unit]
    return dt.datetime.now(dt.timezone.utc) - delta


def _connect_postgres():
    """Return a Postgres connection if one is available, else None."""
    if psycopg is None or not PG_PASS:
        return None
    try:
        return psycopg.connect(
            f"postgresql://{PG_USER}:{PG_PASS}@{PG_HOST}:{PG_PORT}/{PG_NAME}",
            connect_timeout=2,
        )
    except Exception:  # noqa: BLE001
        return None


def _connect_sqlite() -> sqlite3.Connection | None:
    if not DB_PATH.exists():
        return None
    return sqlite3.connect(str(DB_PATH))


def _events_since(since: dt.datetime,
                  tenant: str | None = None,
                  profile: str | None = None) -> list[dict]:
    """Query events since a window. Backend priority: Postgres → SQLite.

    Phase 7 multi-tenant: when called with --tenant, only events for that
    tenant come back. Combined with --profile, you get a per-tenant per-
    role distill (e.g., "what did Acme's coder profile do this week").

    Returns a list of dicts (uniform shape across both backends) so the
    summarize/render code doesn't care where data came from.
    """
    rows: list[dict] = []
    pg_conn = _connect_postgres()
    if pg_conn is not None:
        try:
            with pg_conn:
                with pg_conn.cursor() as cur:
                    sql = """
                        SELECT id, ts, profile, tenant, actor, category, action, subject,
                               payload, outcome, trace_id, cost_usd, tokens_in, tokens_out
                        FROM event_log
                        WHERE ts >= %s
                    """
                    params: list = [since]
                    if tenant is not None:
                        sql += " AND tenant = %s"
                        params.append(tenant)
                    if profile is not None:
                        sql += " AND profile = %s"
                        params.append(profile)
                    sql += " ORDER BY ts ASC"
                    cur.execute(sql, params)
                    cols = [d[0] for d in cur.description]
                    rows = [dict(zip(cols, r)) for r in cur.fetchall()]
        finally:
            pg_conn.close()

    # Always check SQLite too — there may be events from before Postgres
    # was reachable (graceful migration window). De-dup is by trace_id +
    # ts; collisions across backends are extremely unlikely in practice.
    sl = _connect_sqlite()
    if sl is not None:
        sl.row_factory = sqlite3.Row
        sql = """
            SELECT id, ts, profile, tenant, actor, category, action, subject,
                   payload, outcome, trace_id, cost_usd, tokens_in, tokens_out
            FROM events
            WHERE ts >= ?
        """
        params: list = [since.strftime("%Y-%m-%d %H:%M:%S")]
        if tenant is not None:
            sql += " AND tenant = ?"
            params.append(tenant)
        if profile is not None:
            sql += " AND profile = ?"
            params.append(profile)
        sql += " ORDER BY ts ASC"
        sqlite_rows = [dict(r) for r in sl.execute(sql, params).fetchall()]
        sl.close()
        # If we have Postgres rows, only include SQLite rows older than the
        # earliest Postgres row (i.e., from the migration window). Otherwise
        # include all SQLite rows.
        if rows:
            earliest_pg = min(r["ts"] for r in rows)
            # ts comparison: PG returns datetime, SQLite returns string.
            # Normalize SQLite ts to string of PG ts for compare.
            earliest_pg_str = earliest_pg.strftime("%Y-%m-%d %H:%M:%S") if hasattr(earliest_pg, "strftime") else str(earliest_pg)
            sqlite_rows = [r for r in sqlite_rows if str(r["ts"]) < earliest_pg_str]
        rows = sqlite_rows + rows
    return rows


def _summarize(rows: list[dict]) -> dict:
    """Bucket rows for the markdown output. Pure function; no side effects."""
    by_category: defaultdict[str, list] = defaultdict(list)
    outcomes: Counter = Counter()
    actors: Counter = Counter()
    failures: list[dict] = []
    successes_by_subject: defaultdict[str, int] = defaultdict(int)
    cost = 0.0

    for r in rows:
        d = dict(r)
        if d.get("payload") and isinstance(d["payload"], str):
            try:
                d["payload"] = json.loads(d["payload"])
            except (json.JSONDecodeError, TypeError):
                pass
        by_category[d["category"]].append(d)
        outcomes[d["outcome"]] += 1
        actors[d["actor"]] += 1
        if d["outcome"] != "ok":
            failures.append(d)
        else:
            key = f"{d['category']}:{d['subject']}" if d.get("subject") else d["category"]
            successes_by_subject[key] += 1
        if d.get("cost_usd"):
            cost += d["cost_usd"]

    # Promotion candidates: subjects that succeeded >= 3 times in the
    # window — likely worth codifying as a manifest entry if not already.
    promotion_candidates = [
        (subj, n) for subj, n in successes_by_subject.items() if n >= 3
    ]
    promotion_candidates.sort(key=lambda x: -x[1])

    return {
        "total": len(rows),
        "by_category": {c: len(v) for c, v in by_category.items()},
        "outcomes": dict(outcomes),
        "actors": dict(actors),
        "failures": failures,
        "promotion_candidates": promotion_candidates,
        "cost_usd": cost,
    }


def _markdown(summary: dict, since: dt.datetime, until: dt.datetime) -> str:
    """Render the distill markdown. Audience: a human reviewer. Format
    optimizes for: skim → decide → merge or reject without leaving the diff."""
    parts = [
        f"# Curator distill — {until.strftime('%Y-%m-%d')}",
        "",
        f"_Window: {since.isoformat()} → {until.isoformat()}_",
        f"_Total events: {summary['total']}_",
        f"_Cost: ${summary['cost_usd']:.4f}_" if summary["cost_usd"] else "_Cost: not tracked_",
        "",
        "## At a glance",
        "",
        "| metric | value |",
        "|---|---|",
        f"| events by category | {', '.join(f'{c}={n}' for c, n in summary['by_category'].items()) or '(none)'} |",
        f"| outcomes | {', '.join(f'{o}={n}' for o, n in summary['outcomes'].items())} |",
        f"| actors | {', '.join(f'{a}={n}' for a, n in summary['actors'].items())} |",
        "",
    ]

    if summary["promotion_candidates"]:
        parts += [
            "## Promotion candidates",
            "",
            "_Subjects that succeeded 3+ times this window — consider whether they "
            "belong in the manifest if not already there._",
            "",
        ]
        for subj, n in summary["promotion_candidates"][:15]:
            parts.append(f"- **{subj}** — used {n}x")
        parts.append("")

    if summary["failures"]:
        parts += [
            "## Failures (review for patterns)",
            "",
            f"_{len(summary['failures'])} non-ok event(s) in window. Recurring "
            "failures may need a guardrail or a manifest update._",
            "",
        ]
        for f in summary["failures"][:30]:
            payload = f.get("payload", {})
            extra = ""
            if isinstance(payload, dict):
                if "error_class" in payload:
                    extra = f" ({payload['error_class']})"
            parts.append(
                f"- `{f['ts']}` **{f['category']}.{f['action']}** "
                f"on `{f['subject'] or '?'}`{extra} → {f['outcome']}"
            )
        if len(summary["failures"]) > 30:
            parts.append(f"_…and {len(summary['failures']) - 30} more_")
        parts.append("")

    parts += [
        "## Suggested actions",
        "",
        "- [ ] Review promotion candidates — add to relevant manifest if novel.",
        "- [ ] Address recurring failures — codify a lesson or guardrail.",
        "- [ ] Once reviewed, delete this distill file (kept under "
        "`iris-curator-pending/`).",
        "",
        "---",
        "",
        "_Generated by iris-curator. Source: /opt/data/iris-events.db. "
        "Re-run via `iris-curator --since 24h` for the latest snapshot._",
    ]

    return "\n".join(parts)


def _git(*args, check: bool = True) -> subprocess.CompletedProcess:
    """Run git in REPO_ROOT, capturing output. check=False to allow non-zero."""
    return subprocess.run(
        ["git", "-C", str(REPO_ROOT), *args],
        capture_output=True,
        text=True,
        check=check,
    )


def _dirty_manifests() -> list[str]:
    """Return the subset of MANIFEST_PATHS that have uncommitted changes."""
    dirty: list[str] = []
    for p in MANIFEST_PATHS:
        # `git status --porcelain` shows changes for staged AND unstaged.
        # Empty output for the path = clean.
        result = _git("status", "--porcelain", "--", p, check=False)
        if result.stdout.strip():
            dirty.append(p)
    return dirty


def emit_pr(summary: dict, distill_md: str, until: dt.datetime) -> int:
    """Stage dirty manifest paths and commit them on a new curator branch.
    Caller is responsible for pushing + opening the PR (gh auth lives on host)."""
    dirty = _dirty_manifests()
    if not dirty:
        print("iris-curator: no dirty manifest paths — nothing to commit")
        print("  (event log activity is recorded in the distill markdown for review)")
        return 0

    # Branch name with timestamp so multiple runs on the same day don't collide.
    ts = until.strftime("%Y-%m-%d-%H%M%S")
    branch = f"iris-curator/distill-{ts}"

    orig_branch = _git("rev-parse", "--abbrev-ref", "HEAD").stdout.strip()
    print(f"iris-curator: creating branch {branch} from {orig_branch}")
    _git("checkout", "-b", branch)

    try:
        # Stage ONLY the manifest paths we own — never user WIP elsewhere.
        for p in dirty:
            _git("add", "--", p)

        # Commit message: title + distill markdown as body. The curator's
        # distill IS the PR body; reviewer reads it inline on GitHub.
        title = f"iris-curator: distill {until.strftime('%Y-%m-%d')} ({len(dirty)} manifest path(s))"
        msg_body = (
            f"{title}\n\n"
            f"This commit bundles all manifest changes Iris's wrappers made\n"
            f"in the curator's lookback window. Review the distill below for\n"
            f"context (event counts, promotion candidates, recurring failures).\n\n"
            f"Manifests changed:\n"
            + "\n".join(f"  - {p}" for p in dirty)
            + "\n\n---\n\n"
            + distill_md
        )

        # `git commit` will fire the pre-commit + commit-msg hooks (secret
        # scan + iris-self policy). The branch name `iris-curator/...`
        # is NOT iris-self/* and the message prefix isn't iris-self: so
        # the policy hook treats it as a regular commit.
        result = _git("commit", "-m", msg_body, check=False)
        if result.returncode != 0:
            print(f"iris-curator: commit failed: {result.stdout}\n{result.stderr}", file=sys.stderr)
            _git("checkout", orig_branch, check=False)
            _git("branch", "-D", branch, check=False)
            return 1

        sha = _git("rev-parse", "--short", branch).stdout.strip()
        date_str = until.strftime("%Y-%m-%d")
        body_path = OUT_DIR / f"distill-{date_str}.md"
        print(f"iris-curator: committed {sha} on {branch}")
        print()
        print("  Push + open PR:")
        print(f"    git push origin {branch}")
        print(f'    gh pr create --base main --head {branch} \\')
        print(f'      --title "{title}" --body-file "{body_path}"')
        print()
        print("  Or merge directly to main if you trust the diff:")
        print(f"    git merge --ff-only {branch}")

        _git("checkout", orig_branch, check=False)
    finally:
        # Restore original branch even if anything in the try-block raised.
        if _git("rev-parse", "--abbrev-ref", "HEAD").stdout.strip() != orig_branch:
            _git("checkout", orig_branch, check=False)
    return 0


def cmd_status() -> int:
    """Quick stats — useful for sanity checks. Reports both backends."""
    pg = _connect_postgres()
    if pg is not None:
        try:
            with pg:
                with pg.cursor() as cur:
                    cur.execute("SELECT COUNT(*) FROM event_log")
                    total = cur.fetchone()[0]
                    cur.execute("SELECT category, COUNT(*) FROM event_log GROUP BY category ORDER BY 2 DESC")
                    by_cat = dict(cur.fetchall())
                    cur.execute("SELECT ts, category, action, subject FROM event_log ORDER BY id DESC LIMIT 1")
                    last = cur.fetchone()
            print(f"Event log: postgres://{PG_HOST}/{PG_NAME}.event_log")
            print(f"  total events: {total}")
            print(f"  by category:  {by_cat}")
            if last:
                print(f"  last event:   {last[0]}  {last[1]}.{last[2]} {last[3] or ''}")
        finally:
            pg.close()
    else:
        print(f"Event log: postgres unreachable; falling back to SQLite")

    if DB_PATH.exists():
        sl = sqlite3.connect(str(DB_PATH))
        sl_total = sl.execute("SELECT COUNT(*) FROM events").fetchone()[0]
        sl.close()
        print(f"  sqlite fallback: {DB_PATH}  ({sl_total} events; pre-migration)")
    return 0


def main() -> int:
    p = argparse.ArgumentParser(prog="iris-curator", description=__doc__)
    p.add_argument("--since", default="24h",
                   help="lookback window (e.g., 24h, 7d, 30m). Default: 24h")
    p.add_argument("--print-only", action="store_true",
                   help="print to stdout instead of writing a file")
    p.add_argument("--status", action="store_true",
                   help="show event log stats and exit")
    p.add_argument("--tenant", default=None,
                   help="filter events to this tenant only (Phase 7 multi-tenant)")
    p.add_argument("--profile", default=None,
                   help="filter events to this profile only (researcher | coder | ...)")
    p.add_argument("--emit-pr", action="store_true",
                   help="V2.1: bundle dirty manifest paths into a single curator branch + commit. "
                        "Replaces the per-action iris-self/* commits the V1 wrappers used to make.")
    args = p.parse_args()

    if args.status:
        return cmd_status()

    until = dt.datetime.now(dt.timezone.utc)
    since = _parse_since(args.since)

    rows = _events_since(since, tenant=args.tenant, profile=args.profile)
    if not rows and not DB_PATH.exists() and _connect_postgres() is None:
        print("iris-curator: no event log reachable (Postgres + SQLite both empty)", file=sys.stderr)
        return 1
    summary = _summarize(rows)
    md = _markdown(summary, since, until)

    if args.print_only:
        print(md)
        return 0

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    # Filename includes tenant + profile when set, so multi-tenant distills
    # don't overwrite each other.
    suffix = ""
    if args.tenant:
        suffix += f"-tenant-{args.tenant}"
    if args.profile:
        suffix += f"-profile-{args.profile}"
    out_path = OUT_DIR / f"distill-{until.strftime('%Y-%m-%d')}{suffix}.md"
    out_path.write_text(md)
    print(f"iris-curator: wrote {out_path}  ({summary['total']} events)")

    if args.emit_pr:
        return emit_pr(summary, md, until)
    return 0


if __name__ == "__main__":
    sys.exit(main())
