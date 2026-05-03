#!/opt/hermes/.venv/bin/python
"""Render /opt/data/iris-lessons.jsonl into a markdown summary that
Hermes loads as a user-authored skill at session start.

Why it lives at ~/.hermes/skills/iris-lessons/SKILL.md and not in the
system prompt: per Hermes's docs, user-authored skill markdown is injected
as a USER MESSAGE (not system prompt) to preserve the prompt cache. Lessons
that grow over time would otherwise bust the cache on every session.

Run pattern:
  - Called from the gateway entrypoint at boot, before the gateway starts.
  - Idempotent — overwrites the skill file each time.
  - If the lesson file is empty/missing, creates a benign no-op SKILL.md
    so Hermes doesn't see a broken skill.

The output skill is auto-loaded by Hermes and surfaced into Iris's
context whenever the lessons file has at least one entry.
"""
from __future__ import annotations

import json
import os
import sys
from pathlib import Path

LESSON_FILE = Path(os.environ.get("IRIS_LESSONS_PATH", "/opt/data/iris-lessons.jsonl"))
SKILLS_DIR = Path(os.environ.get("HERMES_SKILLS_DIR", "/opt/data/skills"))
SKILL_NAME = "iris-lessons"
MAX_LESSONS_RENDERED = 50  # cap to avoid runaway prompts; oldest get aged out


def render() -> int:
    """Build and write the SKILL.md. Returns the count of lessons rendered."""
    skill_dir = SKILLS_DIR / SKILL_NAME
    skill_dir.mkdir(parents=True, exist_ok=True)
    skill_path = skill_dir / "SKILL.md"

    lessons: list[dict] = []
    if LESSON_FILE.exists():
        for line in LESSON_FILE.read_text().splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                lessons.append(json.loads(line))
            except json.JSONDecodeError:
                continue

    # Most recent first, capped.
    lessons = lessons[-MAX_LESSONS_RENDERED:]

    if not lessons:
        # Benign empty skill — Hermes loads it but it adds nothing meaningful.
        # Removing the skill entirely would also work; this keeps loading
        # idempotent.
        skill_path.write_text(
            "---\n"
            "name: iris-lessons\n"
            "description: Lessons Iris has learned from past failures.\n"
            "  Empty for now (no recorded failures yet).\n"
            "---\n\n"
            "(no lessons recorded yet)\n"
        )
        return 0

    # Group by category so the agent can scan the section it cares about.
    by_cat: dict[str, list[dict]] = {}
    for lesson in lessons:
        by_cat.setdefault(lesson.get("category", "other"), []).append(lesson)

    parts = [
        "---",
        "name: iris-lessons",
        "description: Lessons Iris has learned from past failures. Read these "
        "before attempting iris-* wrapper actions; they save you from "
        "rediscovering what doesn't work.",
        "---",
        "",
        "# Lessons from past failures",
        "",
        f"_{len(lessons)} lessons across {len(by_cat)} categories. "
        "Newer lessons appear later in each section._",
        "",
    ]

    for cat in sorted(by_cat):
        parts.append(f"## category: {cat}")
        parts.append("")
        for lesson in by_cat[cat]:
            ts = lesson.get("ts", "?")
            subject = lesson.get("subject", "?")
            err_class = lesson.get("error_class", "")
            text = lesson.get("lesson", "")
            err_tag = f" ({err_class})" if err_class else ""
            parts.append(f"- **{subject}**{err_tag} — {text}")
            parts.append(f"  _{ts}_")
        parts.append("")

    skill_path.write_text("\n".join(parts))
    return len(lessons)


def main() -> int:
    try:
        n = render()
        print(f"iris-lessons-render: rendered {n} lesson(s) into {SKILLS_DIR / SKILL_NAME}/SKILL.md")
        return 0
    except Exception as e:  # noqa: BLE001
        print(f"iris-lessons-render: WARNING — {e}", file=sys.stderr)
        return 0  # never fail the boot


if __name__ == "__main__":
    sys.exit(main())
