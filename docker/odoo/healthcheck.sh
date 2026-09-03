#!/usr/bin/env bash
# ===========================================================================
# Container-level healthcheck
# ===========================================================================
# "The process is running" is not health. This asks Odoo to answer a real HTTP
# request AND confirms the database is still reachable, because an Odoo that
# has lost PostgreSQL will happily keep listening while serving errors.
# ===========================================================================
set -Eeuo pipefail

PORT_HTTP="${ODOO_HTTP_PORT:-8069}"

# 1. HTTP liveness. /web/health is Odoo's built-in endpoint and needs no auth.
if ! curl -fsS --max-time 5 "http://127.0.0.1:${PORT_HTTP}/web/health" >/dev/null 2>&1; then
    echo "unhealthy: /web/health did not return success" >&2
    exit 1
fi

# 2. Database reachability from inside the app container.
if ! PGPASSWORD="${PASSWORD:-}" pg_isready \
        -h "${HOST:-db}" -p "${PORT:-5432}" -U "${USER:-odoo}" -q; then
    echo "unhealthy: PostgreSQL is not accepting connections" >&2
    exit 1
fi

exit 0
