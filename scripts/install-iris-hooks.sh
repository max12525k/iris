#!/usr/bin/env bash
# Install the iris repo's pre-commit guard into .git/hooks/.
# .git/hooks/ is per-clone (gitignored by git itself) so this needs to run
# once after cloning, and again if scripts/iris-pre-commit-guard.sh changes.
#
# Run: bash scripts/install-iris-hooks.sh
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
HOOK_SOURCE="$REPO_ROOT/scripts/iris-pre-commit-guard.sh"
HOOK_DEST="$REPO_ROOT/.git/hooks/pre-commit"

if [ ! -f "$HOOK_SOURCE" ]; then
    echo "✗ source missing: $HOOK_SOURCE"
    exit 1
fi

# Symlink so the hook is always in sync with the versioned guard script
ln -sf "../../scripts/iris-pre-commit-guard.sh" "$HOOK_DEST"
chmod +x "$HOOK_SOURCE"
echo "✓ pre-commit hook installed: $HOOK_DEST -> scripts/iris-pre-commit-guard.sh"
echo ""
echo "What it blocks:"
echo "  - Common API key shapes (AWS, GitHub, Stripe, Anthropic, OpenRouter, Google, Slack, JWTs, private keys)"
echo "  - DB URIs with embedded credentials"
echo "  - Personal email addresses (gmail/yahoo/outlook/icloud)"
echo "  - Absolute /Users/<name> paths"
echo "  - 'iris-self:' / 'iris-proposed:' commits on main, or that touch protected paths"
echo ""
echo "Override (only after manual review): git commit --no-verify"
