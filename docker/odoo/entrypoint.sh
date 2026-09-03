#!/usr/bin/env bash
# ===========================================================================
# Container entrypoint
# ===========================================================================
# Renders /etc/odoo/odoo.conf from its template, waits for PostgreSQL to
# accept connections, then execs Odoo as PID 1 so signals reach it directly.
# ===========================================================================
set -Eeuo pipefail

log() { printf '%s [entrypoint] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
die() { log "FATAL: $*"; exit 1; }

TEMPLATE=/etc/odoo/odoo.conf.tmpl
RENDERED=/etc/odoo/odoo.conf

# --- Required configuration -------------------------------------------------
# Fail fast and loudly. A silently defaulted database password is how an
# environment ends up pointing somewhere it was never meant to reach.
: "${HOST:?HOST (database host) is required}"
: "${USER:?USER (database user) is required}"
: "${PASSWORD:?PASSWORD (database password) is required}"

# --- Defaults ---------------------------------------------------------------
export PORT="${PORT:-5432}"
export ODOO_DB_NAME="${ODOO_DB_NAME:-odoo}"
export ODOO_DB_MAXCONN="${ODOO_DB_MAXCONN:-64}"
export ODOO_ADMIN_PASSWD="${ODOO_ADMIN_PASSWD:?ODOO_ADMIN_PASSWD is required}"
export ODOO_WORKERS="${ODOO_WORKERS:-0}"
export ODOO_MAX_CRON_THREADS="${ODOO_MAX_CRON_THREADS:-1}"
export ODOO_LIMIT_MEMORY_SOFT="${ODOO_LIMIT_MEMORY_SOFT:-2147483648}"
export ODOO_LIMIT_MEMORY_HARD="${ODOO_LIMIT_MEMORY_HARD:-2684354560}"
export ODOO_LIMIT_TIME_CPU="${ODOO_LIMIT_TIME_CPU:-60}"
export ODOO_LIMIT_TIME_REAL="${ODOO_LIMIT_TIME_REAL:-120}"
export ODOO_LIMIT_REQUEST="${ODOO_LIMIT_REQUEST:-8192}"
export ODOO_LIST_DB="${ODOO_LIST_DB:-False}"
export ODOO_PROXY_MODE="${ODOO_PROXY_MODE:-True}"
export ODOO_LOG_LEVEL="${ODOO_LOG_LEVEL:-info}"

# --- Guard rails ------------------------------------------------------------
# list_db=True exposes the database manager (create/drop/restore over HTTP).
# Refuse to start a non-development environment with it on.
if [[ "${ENVIRONMENT:-dev}" != "dev" && "${ODOO_LIST_DB}" == "True" ]]; then
    die "ODOO_LIST_DB=True is not permitted in ENVIRONMENT=${ENVIRONMENT}"
fi

# --- Render configuration ---------------------------------------------------
[[ -r "${TEMPLATE}" ]] || die "template ${TEMPLATE} is missing or unreadable"
envsubst < "${TEMPLATE}" > "${RENDERED}"
chmod 0640 "${RENDERED}"
log "rendered ${RENDERED} (workers=${ODOO_WORKERS} list_db=${ODOO_LIST_DB} env=${ENVIRONMENT:-dev})"

# --- Wait for PostgreSQL ----------------------------------------------------
# Compose's depends_on/healthy already gates this, but a database can drop out
# and return; the container must survive that rather than crash-loop.
wait_seconds="${DB_WAIT_TIMEOUT:-90}"
deadline=$(( SECONDS + wait_seconds ))
until PGPASSWORD="${PASSWORD}" pg_isready -h "${HOST}" -p "${PORT}" -U "${USER}" -q; do
    if (( SECONDS >= deadline )); then
        die "PostgreSQL at ${HOST}:${PORT} not ready after ${wait_seconds}s"
    fi
    log "waiting for PostgreSQL at ${HOST}:${PORT} ..."
    sleep 2
done
log "PostgreSQL is accepting connections"

# --- Hand over --------------------------------------------------------------
if [[ "${1:-}" == "odoo" ]]; then
    shift
    log "starting Odoo"
    exec odoo --config="${RENDERED}" "$@"
fi

# Anything else (shell, odoo-bin subcommands, migrations) runs verbatim.
log "exec: $*"
exec "$@"
