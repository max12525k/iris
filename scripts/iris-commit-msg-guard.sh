#!/usr/bin/env bash
# Iris commit-msg guard.
#
# Receives the commit message file as $1 (this is reliable, unlike pre-commit's
# stale .git/COMMIT_EDITMSG).
#
# Runs on EVERY commit. Two checks:
#   1. Vocabulary deny-list scan against the commit message body
#      (sourced from ${HOME}/.claude/security/commit-deny-vocab.txt — see that
#      file for format; skipped silently if absent).
#   2. iris-* policy enforcement (only fires when the message is iris-authored,
#      i.e. starts with `iris-self:` or `iris-proposed:`):
#        - must be on iris-proposed/* or iris-self/* branch
#        - must not touch security-critical paths (compose, Dockerfiles,
#          scripts, hooks, env.example, .gitignore, litellm/config.yaml) —
#          those are human-only
#
# Override (only after manual review): git commit --no-verify

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

COMMIT_MSG_FILE="$1"
COMMIT_MSG=$(cat "$COMMIT_MSG_FILE")

ERRORS=0

# Vocabulary deny-list scan — applies to ALL commits (human + iris-*).
# Catches business names, codenames, identifiers the user has flagged.
VOCAB_FILE="${HOME}/.claude/security/commit-deny-vocab.txt"
if [ -f "$VOCAB_FILE" ]; then
    VOCAB_RX=$(grep -vE '^[[:space:]]*(#|$)' "$VOCAB_FILE" | tr '\n' '|' | sed 's/|$//')
    if [ -n "$VOCAB_RX" ] && echo "$COMMIT_MSG" | grep -iE "$VOCAB_RX" >/dev/null 2>&1; then
        TERM=$(echo "$COMMIT_MSG" | grep -ioE "$VOCAB_RX" | head -1)
        echo "✗ commit message contains vocabulary deny-list term ('$TERM')"
        ERRORS=$((ERRORS + 1))
    fi
fi

# iris-* policy enforcement only applies to iris-authored commits.
# Human commits exit here after the vocab check above.
if ! echo "$COMMIT_MSG" | head -1 | grep -qE '^iris-(self|proposed):'; then
    if [ "$ERRORS" -gt 0 ]; then
        echo ""
        echo "Commit-msg scan blocked the commit ($ERRORS issue(s))."
        echo "If you've reviewed and accept the risk: git commit --no-verify"
        exit 1
    fi
    exit 0
fi

# Branch enforcement
BRANCH=$(git rev-parse --abbrev-ref HEAD)
case "$BRANCH" in
    iris-proposed/*|iris-self/*) ;;
    *)
        echo "✗ iris-authored commit on '$BRANCH' — must be on iris-proposed/* or iris-self/*"
        ERRORS=$((ERRORS + 1))
        ;;
esac

# Protected paths — iris-* commits cannot touch infra
FILES=$(git diff --cached --name-only --diff-filter=ACM)
PROTECTED=(
    '^compose\.yaml$'
    '^compose\.prod\.yaml$'
    '^compose\.override\.yaml$'
    '^iris/Dockerfile\.iris-bridge$'
    '^iris/iris-bridge-entrypoint\.sh$'
    '^iris/compose\.yaml$'
    '^iris/hooks/'
    '^iris/bin/'
    '^claude-cli/Dockerfile$'
    '^claude-cli/compose\.yaml$'
    '^claude-cli/entrypoint\.sh$'
    '^claude-cli/.*\.(sh|py)$'
    '^honcho/compose\.yaml$'
    '^litellm/(compose\.yaml|config\.yaml)$'
    '^scripts/'
    '^env\.example$'
    '^litellm/env\.example$'
    '^\.gitignore$'
    '^Makefile$'
)

for FILE in $FILES; do
    for PATTERN in "${PROTECTED[@]}"; do
        if echo "$FILE" | grep -qE "$PATTERN"; then
            echo "✗ iris-authored commit touches protected path: $FILE — that's human-only"
            ERRORS=$((ERRORS + 1))
            break
        fi
    done
done

if [ "$ERRORS" -gt 0 ]; then
    echo ""
    echo "Commit-msg guard blocked the commit ($ERRORS issue(s))."
    echo "  - vocabulary match: edit the message (or staged content, if pre-commit also flagged) and retry."
    echo "  - iris-policy: human-authored change? drop the 'iris-self:' / 'iris-proposed:' prefix."
    echo "    For Iris: write a proposal markdown at /repo/iris-proposed-changes/<topic>.md instead."
    echo "If you've reviewed and accept the risk: git commit --no-verify"
    exit 1
fi

exit 0
