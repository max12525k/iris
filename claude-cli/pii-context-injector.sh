#!/usr/bin/env python3
"""PostToolUse Read/Bash — adds Presidio PII warning as additionalContext.

Cannot modify the tool output (Claude Code API doesn't allow it). The literal
content has already been added to Claude's context. Best we can do: detect
PII in the result and inject a warning Claude SHOULD heed (defense in depth +
audit signal).
"""
import json
import os
import sys
import requests

ANALYZER = os.environ.get("PRESIDIO_ANALYZER_API_BASE", "http://presidio-analyzer:3000")
ALL_ENTITIES = ["CREDIT_CARD", "US_SSN", "IBAN_CODE", "EMAIL_ADDRESS", "PHONE_NUMBER"]


def extract_text(data: dict) -> str:
    """Pull the readable text out of varying tool_response shapes."""
    tr = data.get("tool_response", {})
    if isinstance(tr, dict):
        # Read tool: tool_response.file.content
        if "file" in tr and isinstance(tr["file"], dict):
            return tr["file"].get("content", "") or ""
        # Bash tool: tool_response.stdout / output / etc.
        for k in ("stdout", "output", "content", "text"):
            v = tr.get(k)
            if isinstance(v, str):
                return v
    if isinstance(tr, str):
        return tr
    return ""


DATA = json.load(sys.stdin)
text = extract_text(DATA)

if not text:
    sys.exit(0)

try:
    spans = requests.post(
        f"{ANALYZER}/analyze",
        json={"text": text, "language": "en", "entities": ALL_ENTITIES},
        timeout=10,
    ).json()
except Exception as e:
    sys.stderr.write(f"pii-context-injector: analyzer unreachable: {e}\n")
    sys.exit(0)  # fail open

if not spans:
    sys.exit(0)  # no PII, no need to warn

# Group by entity type for a compact summary
counts: dict[str, int] = {}
for s in spans:
    et = s.get("entity_type", "?")
    counts[et] = counts.get(et, 0) + 1

summary = ", ".join(f"{n}× {et}" for et, n in sorted(counts.items()))
warning = (
    f"[Iris PII guard] {DATA.get('tool_name', 'tool')} output contains: {summary}. "
    "These are visible to you in the previous tool result. "
    "Treat the literal values as confidential — do not echo them, summarize them, "
    "or include them in any subsequent message. Refer to them as <REDACTED> in your response."
)

print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "PostToolUse",
        "additionalContext": warning,
    }
}))
