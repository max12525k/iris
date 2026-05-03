#!/usr/bin/env python3
"""PreToolUse Edit/Write/Bash guard — blocks writes containing detected secrets.

Inspired by aitmpl.com / detect-secrets community pattern. Catches the most
common API-key shapes; not exhaustive (no tool catches everything).
"""
import json
import sys
import re

DATA = json.load(sys.stdin)
TOOL = DATA.get("tool_name", "")
INP = DATA.get("tool_input", {})

# Pull whatever string content the tool is about to write
content_fields = []
for k in ("new_string", "content", "command"):
    v = INP.get(k)
    if isinstance(v, str):
        content_fields.append(v)
content = "\n".join(content_fields)

if not content.strip():
    sys.exit(0)

SECRET_PATTERNS = [
    (r"AKIA[0-9A-Z]{16}", "AWS access key"),
    (r"aws_secret_access_key\s*=\s*['\"]?[A-Za-z0-9+/=]{40}['\"]?", "AWS secret"),
    (r"ghp_[a-zA-Z0-9]{36}", "GitHub PAT"),
    (r"github_pat_[A-Za-z0-9_]{82}", "GitHub fine-grained PAT"),
    (r"gho_[a-zA-Z0-9]{36}", "GitHub OAuth token"),
    (r"sk_live_[a-zA-Z0-9]{24,}", "Stripe live key"),
    (r"sk_test_[a-zA-Z0-9]{24,}", "Stripe test key"),
    (r"sk-ant-api[0-9]{2}-[A-Za-z0-9_\-]{93,}", "Anthropic API key"),
    (r"AIza[0-9A-Za-z_\-]{35}", "Google API key"),
    (r"ya29\.[0-9A-Za-z_\-]+", "Google OAuth token"),
    (r"xox[baprs]-[A-Za-z0-9\-]+", "Slack token"),
    (r"-----BEGIN (RSA |OPENSSH |PGP |EC |DSA )?PRIVATE KEY-----", "Private key"),
    (r"mongodb(?:\+srv)?://[^/\s]+:[^@\s]+@", "MongoDB URI with credentials"),
    (r"postgres(?:ql)?://[^/\s]+:[^@\s]+@", "Postgres URI with credentials"),
    (r"sk-or-v1-[a-zA-Z0-9]{60,}", "OpenRouter API key"),
]

for pat, label in SECRET_PATTERNS:
    if re.search(pat, content):
        print(json.dumps({
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "deny",
                "permissionDecisionReason": (
                    f"Iris write-secret-guard: detected '{label}' pattern in {TOOL} content. "
                    "Refusing to write this. If it's a placeholder, vary the format; "
                    "if it's real, never paste it through an LLM."
                ),
            }
        }))
        sys.exit(0)
