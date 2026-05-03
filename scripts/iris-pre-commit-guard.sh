#!/usr/bin/env bash
# Iris pre-commit guard — content scan only.
#
# Runs on EVERY commit. Blocks:
#   1. Common API key / secret patterns in any staged content
#   2. Personal identifiers (gmail/yahoo/outlook/icloud emails;
#      absolute /Users/<name> paths revealing host username)
#
# Iris-author / branch / protected-path policy lives in the commit-msg hook,
# not here — pre-commit hook can't read the new commit message reliably
# (.git/COMMIT_EDITMSG is stale from the prior commit until commit-msg runs).
#
# Override (only after manual review): git commit --no-verify

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

FILES=$(git diff --cached --name-only --diff-filter=ACM)
[ -z "$FILES" ] && exit 0

ERRORS=0

# Allowlist for known-safe public test/example values that legitimately appear
# in documentation. Add new ones here, comma-separated. Patterns are anchored.
DOC_ALLOWLIST=(
    'AKIAIOSFODNN7EXAMPLE'   # AWS-published canonical test access key
    'AKIAI44QH8DHBEXAMPLE'   # Another AWS test key in their docs
)

# Note on regex precision: the credential-bearing URI patterns explicitly
# exclude env-var-style placeholders (${VAR}, $VAR), template placeholders
# (<PLACEHOLDER>, {PLACEHOLDER}), and "REPLACE_ME" / "your-*" / "example" /
# "password" stand-ins so docs don't false-positive.
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
    'mongodb(\+srv)?://[^/\s:$<{]+:[A-Za-z0-9._=-]{8,}@|MongoDB URI with credentials'
    'postgres(ql)?://[^/\s:$<{]+:[A-Za-z0-9._=-]{8,}@|Postgres URI with credentials'
    'eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}|JWT token'
)

# Strip known-safe doc allowlist entries before pattern matching
filter_allowlist() {
    local content="$1"
    for safe in "${DOC_ALLOWLIST[@]}"; do
        content=$(echo "$content" | grep -v "$safe")
    done
    echo "$content"
}

for FILE in $FILES; do
    [ -f "$FILE" ] || continue
    # Read file with allowlist entries stripped — keeps real matches, drops doc samples
    FILTERED=$(filter_allowlist "$(cat "$FILE")")
    for ENTRY in "${SECRET_PATTERNS[@]}"; do
        PATTERN="${ENTRY%|*}"
        LABEL="${ENTRY##*|}"
        if echo "$FILTERED" | grep -E "$PATTERN" >/dev/null 2>&1; then
            LINE=$(echo "$FILTERED" | grep -nE "$PATTERN" | head -1 | cut -d: -f1)
            echo "✗ $FILE:$LINE — '$LABEL' pattern detected"
            ERRORS=$((ERRORS + 1))
        fi
    done
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

if [ "$ERRORS" -gt 0 ]; then
    echo ""
    echo "Pre-commit content scan blocked the commit ($ERRORS issue(s))."
    echo "If you've reviewed and accept the risk: git commit --no-verify"
    exit 1
fi

exit 0
