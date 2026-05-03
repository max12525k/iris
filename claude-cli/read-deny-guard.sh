#!/usr/bin/env python3
"""PreToolUse Read/Bash guard — blocks reads of obviously-sensitive paths.

Community workaround for Claude Code's known-buggy settings.json `deny`
rules (Anthropic issues #24846, #6699). Hooks run reliably; deny rules don't.
"""
import json
import sys
import re
import fnmatch
import os

DATA = json.load(sys.stdin)
TOOL = DATA.get("tool_name", "")
INP = DATA.get("tool_input", {})

SENSITIVE = [
    "*.env", ".env", ".env.*", "*/.env", "*/.env.*",
    "*.pem", "*.key", "*.crt", "*.p12", "*.pfx",
    "*credentials*", "*secret*", "*.token",
    "id_rsa", "id_rsa.*", "id_ed25519*", "id_ecdsa*", "id_dsa*",
    ".ssh/*", "*/.ssh/*",
    ".aws/credentials*", "*/.aws/credentials*",
    ".gnupg/*", "*/.gnupg/*",
    ".netrc", "*/.netrc",
]


def is_sensitive(path: str):
    if not path:
        return None
    base = os.path.basename(path).lower()
    full = path.lower()
    for pat in SENSITIVE:
        if fnmatch.fnmatch(base, pat) or fnmatch.fnmatch(full, pat):
            return pat
    return None


block_path = None
block_pat = None

if TOOL == "Read":
    block_path = INP.get("file_path", "")
    block_pat = is_sensitive(block_path)
elif TOOL == "Bash":
    cmd = INP.get("command", "")
    READ_VERBS = r"\b(cat|less|more|head|tail|grep|awk|sed|tac|nl|xxd|od|strings|file|stat|wc)\b"
    if re.search(READ_VERBS, cmd):
        for token in re.findall(r"\S+", cmd):
            pat = is_sensitive(token)
            if pat:
                block_path = token
                block_pat = pat
                break
    if not block_pat:
        redir = re.search(r"<\s*(\S+)", cmd)
        if redir:
            token = redir.group(1)
            pat = is_sensitive(token)
            if pat:
                block_path = token
                block_pat = pat

if block_pat:
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": (
                f"Iris read-deny-guard: '{block_path}' matches sensitive pattern '{block_pat}'. "
                "If you need this, route through iris-private (local Ollama, never leaves the machine)."
            ),
        }
    }))
