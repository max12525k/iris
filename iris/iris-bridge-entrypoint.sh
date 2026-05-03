#!/usr/bin/env bash
# Wraps upstream Hermes entrypoint to fix /opt/hermes/ui-tui ownership.
# Must run before privilege drop. Upstream entrypoint remaps hermes UID/GID
# from build-time defaults to HERMES_UID/HERMES_GID at runtime, but doesn't
# chown /opt/hermes/ui-tui — which the dashboard's --tui flag needs to
# `npm install` into. Without this, npm install fails with EACCES.
set -e

if [ "$(id -u)" = "0" ]; then
    chown -R "${HERMES_UID:-10000}:${HERMES_GID:-10000}" /opt/hermes/ui-tui 2>/dev/null || true

    # Configure git identity for iris-authored commits on iris-proposed/* branches.
    # /repo is bind-mounted from host; the .git there is the user's repo, so we
    # set safe.directory + identity at the system level so any user inside the
    # container can run git operations on /repo.
    if [ -d /repo/.git ]; then
        git config --system --add safe.directory /repo 2>/dev/null || true
        git config --system user.name  "${IRIS_BOT_NAME:-iris-bot}" 2>/dev/null || true
        git config --system user.email "${IRIS_BOT_EMAIL:-iris-bot@local}" 2>/dev/null || true
    fi
fi

exec /opt/hermes/docker/entrypoint.sh "$@"
