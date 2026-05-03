#!/usr/bin/env bash
# Layer 3: Mask PII in Read/Bash tool output before Claude adds it to context
# for the next Anthropic turn.
#
# stdin schema (from Claude Code):
#   { "hook_event_name": "PostToolUse",
#     "tool_name": "Read"|"Bash"|...,
#     "tool_input": {...},
#     "tool_output": {"content": "..."} }
#
# stdout schema (to modify):
#   { "hookSpecificOutput": { "hookEventName": "PostToolUse",
#                             "modifiedOutput": "<masked content>" } }
set -euo pipefail

INPUT=$(cat)
CONTENT=$(echo "$INPUT" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("tool_output",{}).get("content",""))')

if [ -z "$CONTENT" ]; then
  exit 0
fi

MASKED=$(printf '%s' "$CONTENT" \
  | python3 -c 'import json,sys; print(json.dumps({"text": sys.stdin.read(), "mode": "mask"}))' \
  | /usr/local/bin/presidio-mask \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["text"])')

# If unchanged, no need to emit anything (saves a transcript record)
if [ "$MASKED" = "$CONTENT" ]; then
  exit 0
fi

python3 -c '
import json, sys
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "PostToolUse",
        "modifiedOutput": sys.argv[1]
    }
}))' "$MASKED"
