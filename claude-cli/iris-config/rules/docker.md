# Docker rules

Read when working with `docker`, `docker compose`, `Dockerfile`, images, or containers. Complements (does not duplicate) Claude Code's built-in safety rules on destructive ops.

## Hard rules for Dockerfiles

- **Run as non-root.** Add `USER <name>` for any image that runs a long-lived process. Default `root` is a known foothold.
- **Multi-stage builds** when there are build-time deps (compilers, dev packages). Final stage carries runtime artifacts only.
- **Pin base images** by tag *and* digest where stability matters: `python:3.13-slim@sha256:…`. Prefer pinned digests over `:latest`.
- **One process per container.** No `supervisord` / `init` wrappers unless a real reason exists.
- **Add a `HEALTHCHECK`** for every long-lived service. For HTTP services, target the readiness endpoint.
- **Layer order:** OS deps → language deps → app code → entrypoint. Cache reuse depends on this.
- **`.dockerignore` must exclude:** `.env*`, `.git`, `__pycache__`, `.venv`, `node_modules`, `*.log`, `.claude/`. Otherwise the build context leaks secrets and bloats.

## Compose rules

- **Use `env_file:`** to inject secrets, never inline `environment:` with literal values.
- **`depends_on` with conditions** (`service_healthy`, `service_started`) — bare deps don't wait for readiness.
- **Networks:** put internal services on an internal network. Only publish ports the host actually needs.
- **Volumes:** prefer named volumes for state, bind mounts only for live-edit dev workflows.
- **Profiles** (`profiles: ["dev"]`) for services that don't run by default — keeps `docker compose up` lean.

## Build performance

- **BuildKit cache mounts** for package managers: `RUN --mount=type=cache,target=/root/.cache/uv uv sync …`.
- **Don't `COPY . .` early** — busts cache on every edit. Copy lockfiles first, install, then copy source.

## For multi-provider gateways (LiteLLM)

- Provider keys live in `.env` (gitignored), surfaced via `env_file:`. Never in `command:` args (visible in `docker inspect`).
- Healthcheck on `/health/readiness` (already allowlisted in `settings.local.json`).
- `LITELLM_MASTER_KEY` is a meta-credential — see `~/.claude/rules/secrets.md`.

## Investigate before destructive ops

- `docker system prune -a` removes unused images globally. Confirm before running.
- `docker compose down -v` deletes named volumes (data loss). Only run with explicit ask.
- Untagged images and dangling volumes may be in-progress work — surface, don't auto-clean.

---
**Sources:** [CIS Docker Benchmark](https://www.cisecurity.org/benchmark/docker), [NIST SP 800-190 — Container Security Guide](https://csrc.nist.gov/pubs/sp/800/190/final), [Docker — Best practices for writing Dockerfiles](https://docs.docker.com/build/building/best-practices/), [Trail of Bits — claude-code-devcontainer](https://github.com/trailofbits/claude-code-devcontainer).
