#!/usr/bin/env bash
# Initialize .env files with generated DB passwords + LiteLLM master/salt keys.
# Idempotent: if .env files already exist, prints a warning and exits without
# clobbering them.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [ -f "$ROOT/.env" ] || [ -f "$ROOT/litellm/.env" ]; then
  echo "✗ .env files already exist:"
  [ -f "$ROOT/.env" ] && echo "    $ROOT/.env"
  [ -f "$ROOT/litellm/.env" ] && echo "    $ROOT/litellm/.env"
  echo ""
  echo "Refusing to overwrite. If you want to start fresh, delete them first:"
  echo "    rm $ROOT/.env $ROOT/litellm/.env"
  exit 1
fi

if ! command -v openssl >/dev/null; then
  echo "✗ openssl not found — install it via your package manager"
  echo "    macOS:        brew install openssl"
  echo "    Ubuntu/Deb:   sudo apt-get install openssl"
  echo "    RHEL/Fedora:  sudo dnf install openssl"
  exit 1
fi

echo "→ Generating top-level .env (DB passwords + host UID/GID)"
cp "$ROOT/env.example" "$ROOT/.env"

LITELLM_DB_PW=$(openssl rand -hex 32)
HONCHO_DB_PW=$(openssl rand -hex 32)
HOST_UID=$(id -u)
HOST_GID=$(id -g)

sed -i.bak \
  -e "s|HERMES_UID=501|HERMES_UID=$HOST_UID|" \
  -e "s|HERMES_GID=20|HERMES_GID=$HOST_GID|" \
  -e "s|LITELLM_DB_PASSWORD=replace-me-with-openssl-rand-hex-32|LITELLM_DB_PASSWORD=$LITELLM_DB_PW|" \
  -e "s|HONCHO_DB_PASSWORD=replace-me-with-openssl-rand-hex-32|HONCHO_DB_PASSWORD=$HONCHO_DB_PW|" \
  "$ROOT/.env"
rm "$ROOT/.env.bak"

echo "→ Generating litellm/.env (master + salt keys; OpenRouter key still TODO)"
cp "$ROOT/litellm/env.example" "$ROOT/litellm/.env"

LITELLM_MASTER=$(openssl rand -hex 32)
LITELLM_SALT=$(openssl rand -hex 32)

sed -i.bak \
  -e "s|LITELLM_MASTER_KEY=sk-replace-me|LITELLM_MASTER_KEY=sk-$LITELLM_MASTER|" \
  -e "s|LITELLM_SALT_KEY=sk-replace-me|LITELLM_SALT_KEY=sk-$LITELLM_SALT|" \
  "$ROOT/litellm/.env"
rm "$ROOT/litellm/.env.bak"

echo ""
echo "✓ .env files created with generated secrets:"
echo "    $ROOT/.env"
echo "    $ROOT/litellm/.env"
echo ""
echo "→ NEXT: add your OpenRouter API key to litellm/.env (replace 'sk-or-...')"
echo "    Get one at https://openrouter.ai/keys"
echo ""
echo "Then run: make dev"
