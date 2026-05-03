#!/usr/bin/env bash
# Hermes pre_tool_call hook — Layer 1 PII gate for terminal commands that
# invoke `claude`. Reads Hermes hook payload (JSON) from stdin.
#
# If tool != terminal or command doesn't start with `claude`, pass through.
# Otherwise extract the prompt arg, mask via Presidio (block-on-match), and
# rewrite the command. On BLOCK, exit 1 to veto the tool call.
set -euo pipefail

PAYLOAD=$(cat)
TOOL=$(echo "$PAYLOAD" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("tool",""))')
CMD=$(echo "$PAYLOAD" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("args",{}).get("command",""))')

# Pass-through for non-terminal tools or non-claude commands
case "$TOOL:$CMD" in
  terminal:claude*) ;;
  *) echo "$PAYLOAD"; exit 0 ;;
esac

# Extract prompt arg (-p '...' or --print '...')
PROMPT=$(python3 -c '
import shlex, sys
toks = shlex.split(sys.argv[1])
for i, t in enumerate(toks):
    if t in ("-p", "--print") and i + 1 < len(toks):
        print(toks[i+1])
        break
' "$CMD")

if [ -z "$PROMPT" ]; then
  # Interactive mode (no -p) — pass through unchanged
  echo "$PAYLOAD"; exit 0
fi

# Mask via Presidio (block on CC/SSN/IBAN matches)
MASKED_JSON=$(printf '%s' "$PROMPT" | python3 -c '
import json, sys
print(json.dumps({"text": sys.stdin.read(), "mode": "block-on-match"}))
' | /usr/local/bin/presidio-mask) || RC=$?
RC=${RC:-0}

if [ "$RC" -eq 1 ]; then
  echo "{\"veto\": true, \"reason\": \"Layer-1 Presidio BLOCK on prompt\"}" >&2
  exit 1
fi
if [ "$RC" -ne 0 ]; then
  echo "presidio-mask returned $RC; passing through unredacted" >&2
  echo "$PAYLOAD"; exit 0
fi

MASKED_PROMPT=$(echo "$MASKED_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["text"])')

# Rewrite command with masked prompt (preserves all other args)
NEW_CMD=$(python3 -c '
import shlex, sys
orig = shlex.split(sys.argv[1])
masked = sys.argv[2]
out = []
i = 0
while i < len(orig):
    if orig[i] in ("-p", "--print") and i + 1 < len(orig):
        out.append(orig[i]); out.append(masked); i += 2
    else:
        out.append(orig[i]); i += 1
print(shlex.join(out))
' "$CMD" "$MASKED_PROMPT")

# Emit modified payload — Hermes uses this rewritten command
echo "$PAYLOAD" | python3 -c '
import json, sys
d = json.load(sys.stdin)
d["args"]["command"] = sys.argv[1]
print(json.dumps(d))
' "$NEW_CMD"
