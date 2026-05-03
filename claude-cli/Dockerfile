FROM node:22-slim

# Claude Code CLI + Python (for presidio-mask helper used by hooks)
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 python3-requests ca-certificates \
  && rm -rf /var/lib/apt/lists/*
RUN npm install -g @anthropic-ai/claude-code

ARG HERMES_UID=10000
ARG HERMES_GID=10000
# Reuse existing group at HERMES_GID if one already exists (e.g. dialout=20 on Debian)
RUN (getent group ${HERMES_GID} >/dev/null || groupadd -g ${HERMES_GID} claude) && \
    useradd -m -u ${HERMES_UID} -g ${HERMES_GID} -s /bin/bash claude

# presidio-mask helper + four Claude Code hook scripts (G.9 / G.11)
COPY --chown=claude:claude presidio-mask.py /usr/local/bin/presidio-mask
COPY --chown=claude:claude presidio-mask-prompt.sh /usr/local/bin/presidio-mask-prompt
COPY --chown=claude:claude read-deny-guard.sh /usr/local/bin/read-deny-guard
COPY --chown=claude:claude write-secret-guard.sh /usr/local/bin/write-secret-guard
COPY --chown=claude:claude pii-context-injector.sh /usr/local/bin/pii-context-injector
RUN chmod +x \
    /usr/local/bin/presidio-mask \
    /usr/local/bin/presidio-mask-prompt \
    /usr/local/bin/read-deny-guard \
    /usr/local/bin/write-secret-guard \
    /usr/local/bin/pii-context-injector

# Pre-create the credential dir owned by claude so the OAuth volume mount inherits.
# Without this, the volume mounts as root-owned and `claude /login` fails to write tokens.
RUN mkdir -p /home/claude/.claude && chown -R claude /home/claude/.claude

# Iris defaults — CLAUDE.md, rules/, agents/, skills/, settings.json with hooks pre-wired.
# Entrypoint copies these into /home/claude/.claude/ on first start (idempotent).
COPY --chown=claude:claude iris-config /home/claude/.claude-defaults
COPY --chown=claude:claude entrypoint.sh /usr/local/bin/iris-init
RUN chmod +x /usr/local/bin/iris-init

USER claude
WORKDIR /workspace

# Entrypoint runs as `claude` and seeds defaults idempotently. If the
# credentials volume is fresh, ownership is correct (Dockerfile pre-creates
# /home/claude/.claude as claude-owned). If it's stale from a prior run,
# do `docker compose exec -T --user root claude-cli chown -R claude /home/claude/.claude`
# once before recreating.
ENTRYPOINT ["/usr/local/bin/iris-init"]
CMD ["tail", "-f", "/dev/null"]
