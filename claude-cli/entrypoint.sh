#!/usr/bin/env bash
# Container init for claude-cli. Runs as ROOT (set in Dockerfile so we can fix
# volume ownership), seeds defaults idempotently, then drops to `claude` user
# via `su` to exec the CMD.
#
# Three responsibilities:
#  1. Reclaim ownership of the credential volume — Docker mounts named volumes
#     as root by default, breaking the unprivileged claude user.
#  2. Seed /home/claude/.claude/ with iris defaults (CLAUDE.md, rules, agents,
#     skills, settings.json with hooks pre-wired) IF missing or empty. After
#     first run, the volume holds the user's evolving copy.
#  3. Symlink /home/claude/.claude.json (Claude Code's runtime state file) into
#     the persistent volume so it survives container recreates.
set -euo pipefail

DEFAULTS_DIR="/home/claude/.claude-defaults"
LIVE_DIR="/home/claude/.claude"
RUNTIME_FILE="/home/claude/.claude.json"
RUNTIME_IN_VOLUME="$LIVE_DIR/runtime.json"

# Note: this script runs as the `claude` user. If volume ownership is wrong,
# seeding will fail loudly (cp: Permission denied). Pre-step documented in
# INSTALL.md G.8: chown -R claude /home/claude/.claude (one-time, as root).

# 1. Seed defaults (only if not already present in the volume)
mkdir -p "$LIVE_DIR"

for src in "$DEFAULTS_DIR"/*; do
  name=$(basename "$src")
  dest="$LIVE_DIR/$name"
  if [ ! -e "$dest" ]; then
    cp -R "$src" "$dest"
    echo "iris-init: seeded $dest (was missing)"
  elif [ -d "$src" ] && [ -d "$dest" ] && [ -z "$(ls -A "$dest" 2>/dev/null)" ]; then
    # Destination directory exists but is empty — seed it
    cp -R "$src/." "$dest/"
    echo "iris-init: seeded $dest (was empty dir)"
  elif [ -f "$src" ] && [ -f "$dest" ] && [ ! -s "$dest" ]; then
    # Destination file exists but is empty (zero bytes) — seed it
    cp "$src" "$dest"
    echo "iris-init: seeded $dest (was empty file)"
  fi
  # Otherwise: destination already has user content — leave alone
done

# 2. Persist .claude.json across recreates by symlinking it into the volume
if [ ! -L "$RUNTIME_FILE" ] && [ ! -e "$RUNTIME_FILE" ]; then
  # No file, no symlink — create the symlink (target may or may not exist yet)
  ln -s "$RUNTIME_IN_VOLUME" "$RUNTIME_FILE"
  echo "iris-init: linked $RUNTIME_FILE -> $RUNTIME_IN_VOLUME"
elif [ -f "$RUNTIME_FILE" ] && [ ! -L "$RUNTIME_FILE" ]; then
  # Plain file exists but isn't a symlink — move it into the volume, then symlink
  mv "$RUNTIME_FILE" "$RUNTIME_IN_VOLUME"
  ln -s "$RUNTIME_IN_VOLUME" "$RUNTIME_FILE"
  echo "iris-init: migrated $RUNTIME_FILE -> $RUNTIME_IN_VOLUME (now symlinked)"
fi

# Hand off to CMD (already running as claude user from Dockerfile USER directive)
exec "$@"
