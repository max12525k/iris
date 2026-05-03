#!/usr/bin/env bash
# Wraps upstream Hermes entrypoint to fix /opt/hermes/ui-tui ownership and
# reconcile Iris's learned packages from the manifest.
#
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

    # ─── Reconcile from learning manifest ───────────────────────────────────
    # Idempotent: already-installed packages are no-ops. Catches the case where
    # the manifest grew (Iris ran iris-learn) but the image hasn't been rebuilt
    # yet — and the case of a fresh force-recreate where the venv has been
    # reset to its image-baked state. Failures are warned, not fatal: Iris
    # should still come up even if a manifest entry can't be installed.
    LEARN_DIR=/repo/iris/iris-learned
    if [ -d "$LEARN_DIR" ]; then
        echo "iris-reconcile: replaying learning manifest from $LEARN_DIR"

        if [ -s "$LEARN_DIR/apt.txt" ]; then
            APT_PKGS=$(grep -vE '^\s*#|^\s*$' "$LEARN_DIR/apt.txt" | tr '\n' ' ')
            if [ -n "$APT_PKGS" ]; then
                (apt-get update -qq && \
                 apt-get install -y --no-install-recommends $APT_PKGS) >/dev/null 2>&1 \
                  || echo "iris-reconcile: WARNING — apt reconcile had issues; check $LEARN_DIR/apt.txt" >&2
            fi
        fi

        if [ -s "$LEARN_DIR/python.txt" ] && grep -qvE '^\s*#|^\s*$' "$LEARN_DIR/python.txt"; then
            su - hermes -s /bin/sh -c \
              "uv pip install --quiet --python /opt/hermes/.venv/bin/python -r '$LEARN_DIR/python.txt'" \
              >/dev/null 2>&1 \
              || echo "iris-reconcile: WARNING — uv pip reconcile had issues; check $LEARN_DIR/python.txt" >&2
        fi

        if [ -s "$LEARN_DIR/npm.txt" ] && command -v npm >/dev/null 2>&1; then
            NPM_PKGS=$(grep -vE '^\s*#|^\s*$' "$LEARN_DIR/npm.txt" | tr '\n' ' ')
            if [ -n "$NPM_PKGS" ]; then
                su - hermes -s /bin/sh -c \
                  "npm config set prefix \$HOME/.local --location=user >/dev/null && npm install -g --silent $NPM_PKGS" \
                  >/dev/null 2>&1 \
                  || echo "iris-reconcile: WARNING — npm reconcile had issues; check $LEARN_DIR/npm.txt" >&2
            fi
        fi
    fi
fi

exec /opt/hermes/docker/entrypoint.sh "$@"
