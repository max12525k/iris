#!/opt/hermes/.venv/bin/python
"""Reconcile Hermes's cron state from iris/iris-config/cron.yaml.

Called by the entrypoint on every boot AND by the iris-cron wrapper after
adding/removing entries. Idempotent: parses Hermes's current cron list,
removes all jobs whose name starts with "iris.", then creates one job per
manifest entry (also prefixed "iris.").

Manual cron jobs (created via `hermes cron create` without the iris. prefix)
are not touched — only Iris-managed entries are reconciled.

Exit codes:
    0 — manifest applied (possibly with per-job warnings on stderr)
    1 — manifest unreadable or hermes binary missing
"""
from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

import yaml

HERMES = "/opt/hermes/.venv/bin/hermes"
DEFAULT_MANIFEST = Path("/repo/iris/iris-config/cron.yaml")


def list_iris_job_ids() -> list[str]:
    """Return Hermes job IDs whose Name starts with 'iris.'."""
    result = subprocess.run(
        [HERMES, "cron", "list"], capture_output=True, text=True, check=False
    )
    ids: list[str] = []
    current_id: str | None = None
    for line in result.stdout.splitlines():
        if id_match := re.match(r"^\s{2,}([a-f0-9]{8,})\s+\[", line):
            current_id = id_match.group(1)
        elif current_id and re.match(r"^\s+Name:\s+iris\.\S+", line):
            ids.append(current_id)
            current_id = None
    return ids


def remove_jobs(ids: list[str]) -> None:
    for job_id in ids:
        subprocess.run(
            [HERMES, "cron", "rm", job_id], capture_output=True, check=False
        )


def create_job(job: dict) -> bool:
    """Run `hermes cron create` for one manifest entry. Returns True on success."""
    try:
        name = job["name"]
        schedule = job["schedule"]
        prompt = job["prompt"]
    except KeyError as e:
        print(f"iris-cron-reconcile: skipping job missing required field {e}", file=sys.stderr)
        return False

    args = [HERMES, "cron", "create", schedule, prompt, "--name", f"iris.{name}"]
    if deliver := job.get("deliver"):
        args += ["--deliver", deliver]
    for skill in job.get("skills") or []:
        args += ["--skill", skill]
    if workdir := job.get("workdir"):
        args += ["--workdir", workdir]

    result = subprocess.run(args, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        msg = result.stderr.strip() or result.stdout.strip() or "unknown error"
        print(f"iris-cron-reconcile: failed to create '{name}' — {msg}", file=sys.stderr)
        return False
    return True


def main(manifest_path: Path) -> int:
    if not Path(HERMES).exists():
        print(f"iris-cron-reconcile: hermes binary missing at {HERMES}", file=sys.stderr)
        return 1
    if not manifest_path.exists():
        print(f"iris-cron-reconcile: manifest missing at {manifest_path} (skipping)")
        return 0

    try:
        data = yaml.safe_load(manifest_path.read_text()) or {}
    except yaml.YAMLError as e:
        print(f"iris-cron-reconcile: manifest unreadable — {e}", file=sys.stderr)
        return 1

    jobs = data.get("jobs") or []
    stale_ids = list_iris_job_ids()
    if stale_ids:
        print(f"iris-cron-reconcile: removing {len(stale_ids)} pre-existing iris.* job(s)")
        remove_jobs(stale_ids)

    if not jobs:
        print("iris-cron-reconcile: manifest is empty — nothing to schedule")
        return 0

    ok = sum(create_job(j) for j in jobs)
    print(f"iris-cron-reconcile: scheduled {ok}/{len(jobs)} job(s) from manifest")
    return 0


if __name__ == "__main__":
    path = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_MANIFEST
    sys.exit(main(path))
