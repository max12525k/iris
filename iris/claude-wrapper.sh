#!/usr/bin/env bash
# claude wrapper inside iris-gateway. Forwards to claude-cli container,
# preserving working directory and stdin/stdout streams.
set -euo pipefail

# Translate iris-gateway's /workspace path → claude-cli's /workspace (same path)
WORKDIR_REL=""
case "$PWD" in
  /workspace*) WORKDIR_REL="$PWD" ;;
  *)           WORKDIR_REL="/workspace" ;;  # fallback
esac

exec docker exec -i -w "$WORKDIR_REL" -u "$(id -u):$(id -g)" claude-cli claude "$@"
