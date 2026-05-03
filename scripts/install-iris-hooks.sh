#!/usr/bin/env bash
# Install the iris repo's pre-commit guard into .git/hooks/.
# .git/hooks/ is per-clone (gitignored by git itself) so this needs to run
# once after cloning, and again if scripts/iris-pre-commit-guard.sh changes.
#
# Run: bash scripts/install-iris-hooks.sh
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"

PRECOMMIT_SRC="$REPO_ROOT/scripts/iris-pre-commit-guard.sh"
COMMITMSG_SRC="$REPO_ROOT/scripts/iris-commit-msg-guard.sh"

for src in "$PRECOMMIT_SRC" "$COMMITMSG_SRC"; do
    [ -f "$src" ] || { echo "✗ missing: $src"; exit 1; }
    chmod +x "$src"
done

# Symlinks so hooks always track the versioned scripts
ln -sf "../../scripts/iris-pre-commit-guard.sh" "$REPO_ROOT/.git/hooks/pre-commit"
ln -sf "../../scripts/iris-commit-msg-guard.sh" "$REPO_ROOT/.git/hooks/commit-msg"

echo "✓ hooks installed:"
echo "    pre-commit -> scripts/iris-pre-commit-guard.sh    (content scan: secrets, PII)"
echo "    commit-msg -> scripts/iris-commit-msg-guard.sh    (iris-* branch + protected-path policy)"
echo ""
echo "What pre-commit blocks (every commit):"
echo "  - Common API key shapes (AWS, GitHub, Stripe, Anthropic, OpenRouter, Google, Slack, JWTs, private keys)"
echo "  - DB URIs with embedded credentials"
echo "  - Personal email addresses (gmail/yahoo/outlook/icloud)"
echo "  - Absolute /Users/<name> paths"
echo ""
echo "What commit-msg blocks (iris-self: / iris-proposed: commits only):"
echo "  - On any branch other than iris-proposed/* or iris-self/*"
echo "  - Touching protected paths (compose, Dockerfiles, scripts, hooks, env.example, etc.)"
echo ""
echo "Override (only after manual review): git commit --no-verify"
