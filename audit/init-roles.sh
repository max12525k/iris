#!/bin/bash
# audit/init-roles.sh — runs at first boot of audit-db (loaded into
# /docker-entrypoint-initdb.d/ alongside schema.sql).
#
# Sets passwords for audit_app + audit_reader from env vars. This keeps
# the actual passwords out of schema.sql (and therefore out of version
# control).
#
# Required env vars:
#   AUDIT_APP_PASSWORD     — password for the INSERT-only role iris connects as
#   AUDIT_READER_PASSWORD  — password for the SELECT-only role Grafana connects as

set -e

if [ -z "$AUDIT_APP_PASSWORD" ] || [ -z "$AUDIT_READER_PASSWORD" ]; then
    echo "audit/init-roles.sh: WARNING — AUDIT_APP_PASSWORD and/or AUDIT_READER_PASSWORD not set; roles will have empty passwords (login will fail)" >&2
fi

psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" <<EOSQL
ALTER ROLE audit_app LOGIN PASSWORD '$AUDIT_APP_PASSWORD';
ALTER ROLE audit_reader LOGIN PASSWORD '$AUDIT_READER_PASSWORD';
EOSQL

echo "audit/init-roles.sh: role passwords set from env"
