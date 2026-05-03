#!/opt/hermes/.venv/bin/python
"""Record a structured 'lesson' that survives across sessions.

Two writes per call:
  1. Append to /opt/data/iris-lessons.jsonl   (always — local source of truth)
  2. POST to Honcho /conclusions               (best-effort — works only when
                                                 Honcho has an embedding key
                                                 configured; silently skipped
                                                 otherwise)

The file-first design means Phase 2 delivers value immediately. When/if
Honcho is wired up with embedding routing in a later phase, conclusions
become semantic-searchable as a bonus.

Usage:
    _record_lesson --category <cat> --subject <sub> --error-class <ec>
                   --lesson "<text>"

A small companion hook (iris/hooks/inject_lessons.py — wired in Phase 2.2)
reads this file at session start and prepends a brief summary into Iris's
context as a user message, so she remembers her own past failures.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import sys
import urllib.error
import urllib.request


LESSON_FILE = os.environ.get("IRIS_LESSONS_PATH", "/opt/data/iris-lessons.jsonl")
HONCHO_BASE = os.environ.get("HONCHO_API_BASE", "http://honcho-api:8000")
HONCHO_WS = os.environ.get("HONCHO_WORKSPACE", "iris-v2")
PEER_ID = os.environ.get("IRIS_BOT_PEER_ID", "iris-bot")
TIMEOUT_S = 5


def _append_local(entry: dict) -> bool:
    """Append one JSON line to the lessons file. The directory is part of
    the data volume (mounted as /opt/data), so lessons survive container
    recreate. Atomic enough for our use — single-writer per profile."""
    try:
        # The data volume is hermes-owned at runtime (see iris-bridge entrypoint).
        os.makedirs(os.path.dirname(LESSON_FILE), exist_ok=True)
        with open(LESSON_FILE, "a") as f:
            f.write(json.dumps(entry) + "\n")
        return True
    except OSError as e:
        print(f"_record_lesson: WARNING — could not append to {LESSON_FILE}: {e}", file=sys.stderr)
        return False


def _try_honcho(content: str) -> bool:
    """Best-effort POST to Honcho. Return True only on real success.
    Quietly returns False on any error class (especially the "OpenAI API key
    required" error from Honcho when no embedding is configured) — the local
    file is the canonical store, Honcho is bonus."""

    def _post(path: str, body: dict) -> int:
        req = urllib.request.Request(
            f"{HONCHO_BASE}{path}",
            data=json.dumps(body).encode(),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=TIMEOUT_S) as resp:
                return resp.status
        except urllib.error.HTTPError as e:
            return e.code
        except (urllib.error.URLError, OSError):
            return 0

    # Lazy create workspace + peer (idempotent — 200 if new, 409 if exists).
    _post("/v3/workspaces", {"id": HONCHO_WS})
    _post(f"/v3/workspaces/{HONCHO_WS}/peers", {"id": PEER_ID})

    code = _post(
        f"/v3/workspaces/{HONCHO_WS}/conclusions",
        {
            "conclusions": [
                {
                    "content": content,
                    "observer_id": PEER_ID,
                    "observed_id": PEER_ID,
                }
            ]
        },
    )
    return code in (200, 201)


def build_content(args: argparse.Namespace) -> str:
    """Lesson text is intentionally machine-greppable AND human-readable."""
    bits = [
        "[lesson:failure]",
        f"category={args.category}",
        f"subject={args.subject}",
    ]
    if args.error_class:
        bits.append(f"error_class={args.error_class}")
    head = " ".join(bits)
    return f"{head}\n{args.lesson}"


def main() -> int:
    p = argparse.ArgumentParser(prog="_record_lesson", description=__doc__)
    p.add_argument("--category", required=True,
                   help="package | skill | cron | mcp")
    p.add_argument("--subject", required=True,
                   help="name/id of what was attempted")
    p.add_argument("--error-class", default="",
                   help="short error category")
    p.add_argument("--lesson", required=True,
                   help="the durable lesson Iris should remember next time")
    args = p.parse_args()

    try:
        entry = {
            "ts": dt.datetime.now(dt.timezone.utc).isoformat(),
            "profile": os.environ.get("HERMES_PROFILE", "default"),
            "tenant": os.environ.get("IRIS_TENANT", ""),
            "category": args.category,
            "subject": args.subject,
            "error_class": args.error_class,
            "lesson": args.lesson,
            "content": build_content(args),
        }
        _append_local(entry)
        # Best-effort secondary write — failure here is not a failure overall.
        _try_honcho(entry["content"])
        return 0
    except Exception as e:  # noqa: BLE001
        print(f"_record_lesson: WARNING — {e}", file=sys.stderr)
        return 0


if __name__ == "__main__":
    sys.exit(main())
