#!/usr/bin/env bash
# Iris commit-msg guard — iris-* policy enforcement.
#
# Receives the commit message file as $1 (this is reliable, unlike pre-commit's
# stale .git/COMMIT_EDITMSG). Blocks iris-authored commits that:
#   1. Aren't on an iris-proposed/* or iris-self/* branch
#   2. Touch security-critical paths (compose, Dockerfiles, scripts, hooks,
#      env.example, .gitignore, litellm/config.yaml) — those are human-only
#
# Override (only after manual review): git commit --no-verify

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

COMMIT_MSG_FILE="$1"
COMMIT_MSG=$(cat "$COMMIT_MSG_FILE")

# Bail out unless this is an iris-* commit
if ! echo "$COMMIT_MSG" | head -1 | grep -qE '^iris-(self|proposed):'; then
    exit 0
fi

ERRORS=0

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
    echo "iris-policy blocked the commit ($ERRORS issue(s))."
    echo "If genuine human-authored change touching protected paths, use a regular commit message"
    echo "(no 'iris-self:' / 'iris-proposed:' prefix). For Iris: write a proposal markdown at"
    echo "/repo/iris-proposed-changes/<topic>.md instead."
    exit 1
fi

exit 0
