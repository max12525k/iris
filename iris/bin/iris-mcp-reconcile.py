#!/opt/hermes/.venv/bin/python
"""Reconcile Hermes's MCP server config from iris/iris-config/mcp.yaml.

Called by the entrypoint on every boot AND by the iris-mcp wrapper after
add/rm. For each entry in the manifest, runs `hermes mcp add` with overwrite
semantics (auto-accepting the "already exists?" and "save anyway?" prompts).

Removal semantics: this reconcile is *additive only*. Servers in the manifest
get added/upserted; servers not in the manifest are not touched. Use
`iris-mcp rm` to remove a server from both the manifest AND Hermes config.

Exit codes:
    0 — manifest applied (per-server failures still warn on stderr)
    1 — manifest unreadable or hermes binary missing
"""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import yaml

HERMES = "/opt/hermes/.venv/bin/hermes"
DEFAULT_MANIFEST = Path("/repo/iris/iris-config/mcp.yaml")


def add_server(server: dict) -> bool:
    """Run `hermes mcp add` for one manifest entry. Returns True on success.

    Uses `yes` to auto-accept the interactive prompts:
      "Server 'X' already exists. Overwrite? [y/N]"
      "Connecting…  ✗ Failed.  Save config anyway? [y/N]"
    Both default to N, so we feed "y" repeatedly to ensure both pass.
    """
    name = server.get("name")
    if not name:
        print("iris-mcp-reconcile: skipping entry missing 'name'", file=sys.stderr)
        return False

    args = [HERMES, "mcp", "add", name]
    if url := server.get("url"):
        args += ["--url", url]
    if command := server.get("command"):
        args += ["--command", command]
    if cmd_args := server.get("args"):
        args += ["--args", *cmd_args]
    if auth := server.get("auth"):
        args += ["--auth", auth]
    if preset := server.get("preset"):
        args += ["--preset", preset]
    for env in server.get("env") or []:
        args += ["--env", env]

    # Pipe enough "y" lines to cover both potential prompts.
    result = subprocess.run(
        args, input="y\ny\n", capture_output=True, text=True, check=False, timeout=30
    )
    if result.returncode != 0:
        msg = result.stderr.strip() or result.stdout.strip() or "unknown error"
        print(f"iris-mcp-reconcile: failed to add '{name}' — {msg}", file=sys.stderr)
        return False
    return True


def main(manifest_path: Path) -> int:
    if not Path(HERMES).exists():
        print(f"iris-mcp-reconcile: hermes binary missing at {HERMES}", file=sys.stderr)
        return 1
    if not manifest_path.exists():
        print(f"iris-mcp-reconcile: manifest missing at {manifest_path} (skipping)")
        return 0

    try:
        data = yaml.safe_load(manifest_path.read_text()) or {}
    except yaml.YAMLError as e:
        print(f"iris-mcp-reconcile: manifest unreadable — {e}", file=sys.stderr)
        return 1

    servers = data.get("servers") or []
    if not servers:
        print("iris-mcp-reconcile: manifest is empty — nothing to add")
        return 0

    ok = sum(add_server(s) for s in servers)
    print(f"iris-mcp-reconcile: applied {ok}/{len(servers)} server(s) from manifest")
    return 0


if __name__ == "__main__":
    path = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_MANIFEST
    sys.exit(main(path))
