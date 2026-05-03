#!/usr/bin/env bash
# Backs up databases and named volumes to ./backups/<date>/

set -euo pipefail

BACKUP_DIR="$(dirname "$0")/../backups/$(date +%F)"
mkdir -p "$BACKUP_DIR"

cd "$(dirname "$0")/.."

echo "Backing up to $BACKUP_DIR"

# Postgres dumps (logical, version-portable)
docker compose exec -T litellm-db pg_dump -U llmproxy litellm | gzip > "$BACKUP_DIR/litellm.sql.gz"
docker compose exec -T honcho-db pg_dump -U postgres postgres | gzip > "$BACKUP_DIR/honcho.sql.gz"

# Iris data volume (raw tar — Iris uses SQLite + skill state)
docker run --rm \
  -v iris_data:/data \
  -v "$(realpath "$BACKUP_DIR")":/backup \
  alpine tar czf /backup/iris_data.tar.gz -C /data .

# Rotate: keep last 7 days
find "$(dirname "$0")/../backups" -mindepth 1 -maxdepth 1 -type d -mtime +7 -exec rm -rf {} + 2>/dev/null || true

echo "✓ Backup complete: $BACKUP_DIR"
/bin/ls -lh "$BACKUP_DIR"
