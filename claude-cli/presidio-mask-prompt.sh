#!/usr/bin/env bash
# Layer 2: BLOCK prompts containing high-risk PII (CC, SSN, IBAN).
# Claude Code's UserPromptSubmit protocol does NOT permit modifying the prompt —
# only blocking it (decision: "block") or adding context. So we run Presidio in
# block-on-match mode; if it returns RC=1 (financial PII matched), we tell
# Claude Code to reject the request.
set -euo pipefail

INPUT=$(cat)
PROMPT=$(echo "$INPUT" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("prompt",""))')

if [ -z "$PROMPT" ]; then
  exit 0
fi

# Run Presidio in block-on-match mode (financial PII only)
ERR_FILE=$(mktemp)
if printf '%s' "$PROMPT" \
   | python3 -c 'import json,sys; print(json.dumps({"text": sys.stdin.read(), "mode": "block-on-match"}))' \
   | /usr/local/bin/presidio-mask >/dev/null 2>"$ERR_FILE"
then
  rm -f "$ERR_FILE"
  exit 0  # No financial PII — pass through
fi

REASON=$(head -1 "$ERR_FILE" 2>/dev/null || echo "Presidio match")
rm -f "$ERR_FILE"

case "$REASON" in
  *"BLOCK on"*)
    REASON="$REASON" python3 <<'PYEOF'
import json
import os
print(json.dumps({
    "decision": "block",
    "reason": "Iris privacy guard: high-risk PII detected in prompt. " + os.environ["REASON"],
    "hookSpecificOutput": {"hookEventName": "UserPromptSubmit"}
}))
PYEOF
    exit 0
    ;;
  *)
    echo "presidio-mask config error: $REASON" >&2
    exit 0  # Fail open on config errors
    ;;
esac
