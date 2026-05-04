#!/usr/bin/env bash
# Mint a virtual key in LiteLLM for Iris's default workflow, save it to .env,
# and configure iris-gateway to use it via the iris-config/config.template.yaml.
# Idempotent: if a key already exists in .env, exits without minting another
# (use --force to rotate).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMPLATE="$ROOT/iris/iris-config/config.template.yaml"
SOUL_SRC="$ROOT/iris/iris-config/SOUL.md"

if [ ! -f "$ROOT/litellm/.env" ]; then
  echo "✗ $ROOT/litellm/.env missing. Run scripts/setup-secrets.sh first."
  exit 1
fi

if [ ! -f "$TEMPLATE" ]; then
  echo "✗ Config template missing: $TEMPLATE"
  exit 1
fi

FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

if [ "$FORCE" = 0 ] && grep -q "^IRIS_VIRTUAL_KEY=sk-" "$ROOT/.env" 2>/dev/null; then
  echo "✓ IRIS_VIRTUAL_KEY already set in .env. Re-applying config from template (key unchanged)."
  IRIS_VKEY=$(grep "^IRIS_VIRTUAL_KEY=" "$ROOT/.env" | cut -d= -f2)
else
  echo "→ Waiting for LiteLLM at http://127.0.0.1:4000 ..."
  until curl -fs --max-time 2 http://127.0.0.1:4000/health/liveliness > /dev/null 2>&1; do
    sleep 2
  done
  echo "✓ LiteLLM is healthy"

  MASTER=$(grep "^LITELLM_MASTER_KEY=" "$ROOT/litellm/.env" | cut -d= -f2)
  if [ -z "$MASTER" ]; then
    echo "✗ LITELLM_MASTER_KEY not found in litellm/.env"
    exit 1
  fi

  # Limits sized for Hermes's multi-call agent loop. A single conversation
  # turn typically chains 3-5 model calls (system prompt + skills catalog +
  # Honcho context + tool rounds + auxiliary models for compression /
  # title_gen / vision). At 100K TPM (the early-stage default), nightly
  # crons + a user message at the same time hit 429. 500K TPM gives
  # comfortable headroom; 200 RPM matches the burstiness of subagent fanout.
  # Budget cap of $50/30d remains unchanged — the TPM/RPM limits don't
  # affect spend, just rate.
  echo "→ Minting virtual key (alias=iris-default, budget=\$50/30d, 200 RPM, 500K TPM)"
  TMPFILE=$(mktemp)
  trap 'rm -f "$TMPFILE"' EXIT

  curl -s -X POST http://127.0.0.1:4000/key/generate \
    -H "Authorization: Bearer $MASTER" \
    -H "Content-Type: application/json" \
    -d '{
      "key_alias": "iris-default",
      "models": ["iris-default", "iris-cheap", "iris-research", "iris-private", "iris-marketing", "iris-coding", "iris-briefing"],
      "max_budget": 50.00,
      "budget_duration": "30d",
      "rpm_limit": 200,
      "tpm_limit": 500000,
      "metadata": {"workflow": "iris"}
    }' > "$TMPFILE"

  IRIS_VKEY=$(python3 -c "import json; print(json.load(open('$TMPFILE'))['key'])")
  if [ -z "$IRIS_VKEY" ] || [ "$IRIS_VKEY" = "None" ]; then
    echo "✗ Key mint failed. Response:"
    cat "$TMPFILE"
    exit 1
  fi

  # Remove any existing IRIS_VIRTUAL_KEY line, then append the fresh one
  sed -i.bak '/^IRIS_VIRTUAL_KEY=/d' "$ROOT/.env" 2>/dev/null && rm -f "$ROOT/.env.bak"
  echo "IRIS_VIRTUAL_KEY=$IRIS_VKEY" >> "$ROOT/.env"
  echo "✓ Saved IRIS_VIRTUAL_KEY to .env"
fi

echo "→ Rendering Iris config from template + virtual key"
RENDERED=$(IRIS_VKEY="$IRIS_VKEY" envsubst '${IRIS_VKEY}' < "$TEMPLATE")

# Write config + SOUL.md into the running iris-gateway. The container's
# entrypoint (G.7) seeds these on first start; this is the manual / re-apply
# path used right after mint.
echo "→ Pushing config.yaml + SOUL.md into iris-gateway"
docker compose exec -T iris-gateway sh -c "
mv /opt/data/config.yaml /opt/data/config.yaml.upstream-example 2>/dev/null || true
cat > /opt/data/config.yaml <<'IRIS_EOF'
$RENDERED
IRIS_EOF
"

# Push SOUL.md (overwrites whatever was there with our personality file)
docker cp "$SOUL_SRC" iris-gateway:/opt/data/SOUL.md

# Fix ownership (files written as root inside container)
docker compose exec -T --user root iris-gateway sh -c \
  "chown hermes:dialout /opt/data/config.yaml /opt/data/SOUL.md && chmod 640 /opt/data/config.yaml /opt/data/SOUL.md"

echo "→ Restarting iris-gateway to load new config"
docker compose restart iris-gateway > /dev/null

echo ""
echo "✓ Iris is wired with optimized config:"
echo "    IRIS_VIRTUAL_KEY=${IRIS_VKEY:0:8}... (saved to .env)"
echo "    /opt/data/config.yaml — 1h prompt cache, explicit compression, aux=main"
echo "    /opt/data/SOUL.md — Iris persona (see iris/iris-config/SOUL.md)"
echo ""
echo "Test inference:"
echo "    curl -s -X POST http://127.0.0.1:4000/v1/chat/completions \\"
echo "      -H 'Authorization: Bearer \$IRIS_VIRTUAL_KEY' \\"
echo "      -H 'Content-Type: application/json' \\"
echo "      -d '{\"model\":\"iris-default\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: pong\"}],\"max_tokens\":200}'"
