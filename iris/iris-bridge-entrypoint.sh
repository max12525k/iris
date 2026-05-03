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
    # Run as root: avoids the usermod-ordering issue (upstream entrypoint
    # remaps hermes from build-time uid 10000 → HERMES_UID later, so su to
    # hermes here would write as the wrong uid). Idempotent: already-installed
    # packages are fast no-ops. Failures warn but don't abort — Iris should
    # still start even if a manifest entry can't be installed.
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
            uv pip install --quiet --python /opt/hermes/.venv/bin/python -r "$LEARN_DIR/python.txt" \
              || echo "iris-reconcile: WARNING — uv pip reconcile had issues; check $LEARN_DIR/python.txt" >&2
        fi

        if [ -s "$LEARN_DIR/npm.txt" ] && command -v npm >/dev/null 2>&1; then
            NPM_PKGS=$(grep -vE '^\s*#|^\s*$' "$LEARN_DIR/npm.txt" | tr '\n' ' ')
            if [ -n "$NPM_PKGS" ]; then
                # Install to hermes's user prefix even though we're root, so
                # global modules end up in a hermes-writable location at runtime.
                npm install -g --prefix /home/hermes/.local --silent $NPM_PKGS \
                  >/dev/null 2>&1 \
                  || echo "iris-reconcile: WARNING — npm reconcile had issues; check $LEARN_DIR/npm.txt" >&2
            fi
        fi
    fi

    # Chown the venv + npm prefix AFTER reconcile so hermes can run iris-learn
    # at runtime without permission errors. Single-pass chown after install
    # covers both the image-baked files and any new ones reconcile just added.
    # ~Idempotent on warm boots.
    chown -R "${HERMES_UID:-10000}:${HERMES_GID:-10000}" /opt/hermes/.venv 2>/dev/null || true
    [ -d /home/hermes/.local ] && \
      chown -R "${HERMES_UID:-10000}:${HERMES_GID:-10000}" /home/hermes/.local 2>/dev/null || true

    # ─── Cron reconcile from iris/iris-config/cron.yaml ─────────────────────
    # Hermes's cron state lives in SQLite at /opt/data/state.db, not in plain
    # config — so we can't just COPY a manifest into the image. Instead, the
    # iris-cron-reconcile helper reads /repo/iris/iris-config/cron.yaml, wipes
    # any pre-existing iris.* jobs in Hermes, and recreates them from the
    # manifest. Same "repo as source of truth" property as packages.
    #
    # Must run as the eventual hermes UID so writes land in /opt/data/state.db
    # with correct ownership. We mirror upstream's usermod + /opt/data chown
    # ourselves (otherwise cron reconcile would write as the wrong UID) and
    # let upstream re-run the same logic harmlessly (it's idempotent).
    NEED_HERMES_RUNTIME=false
    [ -x /usr/local/bin/iris-cron-reconcile ] && [ -f /repo/iris/iris-config/cron.yaml ] && NEED_HERMES_RUNTIME=true
    [ -f /repo/iris/iris-config/skills.json ] && NEED_HERMES_RUNTIME=true
    [ -x /usr/local/bin/iris-mcp-reconcile ] && [ -f /repo/iris/iris-config/mcp.yaml ] && NEED_HERMES_RUNTIME=true

    if [ "$NEED_HERMES_RUNTIME" = true ]; then
        # Mirror upstream's UID/GID + /opt/data chown so subsequent gosu calls
        # write to /opt/data with the correct ownership. Upstream's same logic
        # later runs harmlessly (idempotent).
        if [ -n "${HERMES_UID:-}" ] && [ "$HERMES_UID" != "$(id -u hermes)" ]; then
            usermod -u "$HERMES_UID" hermes
        fi
        if [ -n "${HERMES_GID:-}" ] && [ "$HERMES_GID" != "$(id -g hermes)" ]; then
            groupmod -o -g "$HERMES_GID" hermes 2>/dev/null || true
        fi
        chown -R hermes:"$(id -gn hermes)" /opt/data 2>/dev/null || true

        if [ -x /usr/local/bin/iris-cron-reconcile ] && [ -f /repo/iris/iris-config/cron.yaml ]; then
            gosu hermes /usr/local/bin/iris-cron-reconcile /repo/iris/iris-config/cron.yaml \
              || echo "iris-reconcile: WARNING — cron reconcile had issues; check /repo/iris/iris-config/cron.yaml" >&2
        fi

        # Skills reconcile: import the manifest snapshot. Hermes treats the
        # operation as install-anything-missing (idempotent) so this is fast
        # when nothing has changed and pulls from registries on fresh clones.
        if [ -s /repo/iris/iris-config/skills.json ]; then
            if /opt/hermes/.venv/bin/python -c "
import json, sys
with open('/repo/iris/iris-config/skills.json') as f:
    d = json.load(f)
sys.exit(0 if (d.get('skills') or []) else 1)
" >/dev/null 2>&1; then
                echo "iris-reconcile: replaying skills snapshot from /repo/iris/iris-config/skills.json"
                gosu hermes /opt/hermes/.venv/bin/hermes skills snapshot import \
                    /repo/iris/iris-config/skills.json --force \
                  || echo "iris-reconcile: WARNING — skills reconcile had issues; check /repo/iris/iris-config/skills.json" >&2
            fi
        fi

        # MCP reconcile: replay each manifest entry via `hermes mcp add` with
        # auto-accepted prompts. Idempotent — overwrites existing entries with
        # the same name. Skipped when the manifest has no servers.
        if [ -x /usr/local/bin/iris-mcp-reconcile ] && [ -f /repo/iris/iris-config/mcp.yaml ]; then
            gosu hermes /usr/local/bin/iris-mcp-reconcile /repo/iris/iris-config/mcp.yaml \
              || echo "iris-reconcile: WARNING — mcp reconcile had issues; check /repo/iris/iris-config/mcp.yaml" >&2
        fi
    fi
fi

exec /opt/hermes/docker/entrypoint.sh "$@"
