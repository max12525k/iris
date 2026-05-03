#!/usr/bin/env bash
# Iris repo pre-commit guard.
#
# Runs on EVERY commit (regardless of author). Blocks:
#   1. Common API key / secret patterns in any staged content
#   2. Personal identifiers (emails matching personal-name patterns,
#      absolute /Users/<name> paths revealing host username)
#   3. Iris-authored commits (`iris-self:` / `iris-proposed:` prefix) that
#      touch security-critical paths — those are human-only
#   4. Iris-authored commits that aren't on an iris-proposed/* or
#      iris-self/* branch — main is human-only territory
#
# Install via `bash scripts/install-iris-hooks.sh` after cloning the repo.
# Override (only if you've manually reviewed): `git commit --no-verify`.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

# Files staged for this commit (added or modified, not deleted)
FILES=$(git diff --cached --name-only --diff-filter=ACM)
[ -z "$FILES" ] && exit 0

ERRORS=0

# ─────────── Secret patterns ───────────
SECRET_PATTERNS=(
    'AKIA[0-9A-Z]{16}|AWS access key'
    'aws_secret_access_key\s*=\s*["'"'"']?[A-Za-z0-9+/=]{40}["'"'"']?|AWS secret'
    'ghp_[a-zA-Z0-9]{36}|GitHub PAT'
    'github_pat_[A-Za-z0-9_]{82}|GitHub fine-grained PAT'
    'gho_[a-zA-Z0-9]{36}|GitHub OAuth token'
    'sk_live_[a-zA-Z0-9]{24,}|Stripe live key'
    'sk_test_[a-zA-Z0-9]{24,}|Stripe test key'
    'sk-ant-api[0-9]{2}-[A-Za-z0-9_-]{93,}|Anthropic API key'
    'sk-or-v1-[a-zA-Z0-9]{60,}|OpenRouter API key'
    'AIza[0-9A-Za-z_-]{35}|Google API key'
    'ya29\.[0-9A-Za-z_-]+|Google OAuth token'
    'xox[baprs]-[A-Za-z0-9-]+|Slack token'
    '-----BEGIN (RSA |OPENSSH |PGP |EC |DSA )?PRIVATE KEY-----|Private key'
    'mongodb(\+srv)?://[^/\s]+:[^@\s]+@|MongoDB URI with credentials'
    'postgres(ql)?://[^/\s]+:[^@\s]+@|Postgres URI with credentials'
    'eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}|JWT token'
)

for FILE in $FILES; do
    [ -f "$FILE" ] || continue
    for ENTRY in "${SECRET_PATTERNS[@]}"; do
        PATTERN="${ENTRY%|*}"
        LABEL="${ENTRY##*|}"
        if grep -E "$PATTERN" "$FILE" >/dev/null 2>&1; then
            LINE=$(grep -nE "$PATTERN" "$FILE" | head -1 | cut -d: -f1)
            echo "✗ $FILE:$LINE — '$LABEL' pattern detected"
            ERRORS=$((ERRORS + 1))
        fi
    done
done

# ─────────── Personal data + absolute home paths ───────────
for FILE in $FILES; do
    [ -f "$FILE" ] || continue
    if grep -nE '@gmail\.com|@yahoo\.com|@outlook\.com|@icloud\.com' "$FILE" >/dev/null 2>&1; then
        LINE=$(grep -nE '@gmail|@yahoo|@outlook|@icloud' "$FILE" | head -1 | cut -d: -f1)
        echo "✗ $FILE:$LINE — personal email address (commit publicly?)"
        ERRORS=$((ERRORS + 1))
    fi
    if grep -nE '/Users/[a-zA-Z0-9_-]{2,}' "$FILE" >/dev/null 2>&1; then
        LINE=$(grep -nE '/Users/[a-zA-Z0-9_-]{2,}' "$FILE" | head -1 | cut -d: -f1)
        echo "✗ $FILE:$LINE — absolute /Users/<name> path reveals host username (use ~/ instead)"
        ERRORS=$((ERRORS + 1))
    fi
done

# ─────────── Iris-authored commit policy ───────────
COMMIT_MSG_FILE="${1:-.git/COMMIT_EDITMSG}"
COMMIT_MSG=""
[ -f "$COMMIT_MSG_FILE" ] && COMMIT_MSG=$(cat "$COMMIT_MSG_FILE")

if echo "$COMMIT_MSG" | grep -qE '^iris-(self|proposed):'; then
    # Branch check: iris-* commits must be on iris-proposed/* or iris-self/*
    BRANCH=$(git rev-parse --abbrev-ref HEAD)
    case "$BRANCH" in
        iris-proposed/*|iris-self/*) ;;
        *)
            echo "✗ iris-authored commit on '$BRANCH' — must be on iris-proposed/* or iris-self/*"
            ERRORS=$((ERRORS + 1))
            ;;
    esac

    # Path check: iris-authored commits cannot touch security-critical paths
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
fi

# ─────────── Result ───────────
if [ "$ERRORS" -gt 0 ]; then
    echo ""
    echo "Pre-commit guard blocked the commit ($ERRORS issue(s))."
    echo "If you've reviewed and accept the risk, commit with: git commit --no-verify"
    exit 1
fi

exit 0
