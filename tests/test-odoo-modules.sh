#!/usr/bin/env bash
# ===========================================================================
# tests/test-odoo-modules.sh - run Odoo's own test suite
# ===========================================================================
# Runs Odoo's test runner against a THROWAWAY database cloned from the target
# environment's template, never against the environment's live database.
#
# That matters: `--test-enable` writes. Running it against QA's real database
# would leave test records behind and make QA an unreliable rehearsal of
# production. Running it against production would be an incident.
#
# Usage: tests/test-odoo-modules.sh [-e qa] [-m module,module]
# ===========================================================================
set -Eeuo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_DIR}"

ENVIRONMENT="qa"
MODULES=""

while getopts ":e:m:h" opt; do
    case "${opt}" in
        e) ENVIRONMENT="${OPTARG}" ;;
        m) MODULES="${OPTARG}" ;;
        h) sed -n '2,14p' "$0"; exit 0 ;;
        *) echo "unknown option -${OPTARG}" >&2; exit 2 ;;
    esac
done

log() { printf '%s [odoo-tests] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die() { printf '%s [odoo-tests] FATAL: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; exit 1; }

[[ "${ENVIRONMENT}" != "prod" ]] \
    || die "refusing to run the Odoo test suite against production"

if [[ -r .env ]]; then
    set -a
    # shellcheck disable=SC1091
    . .env
    set +a
fi

: "${ODOO_DB_NAME:?ODOO_DB_NAME is required}"

compose() {
    docker compose -f compose.yml -f "compose.${ENVIRONMENT}.yml" "$@"
}

psql_admin() {
    compose exec -T db sh -c \
        "PGPASSWORD=\"\$POSTGRES_PASSWORD\" psql -U \"\$POSTGRES_USER\" -d postgres -tAc \"$1\"" \
        2>/dev/null | tr -d '[:space:]'
}

# --- Determine which modules to test ---------------------------------------
if [[ -z "${MODULES}" ]]; then
    MODULES="$(compose exec -T odoo sh -c \
        'ls -1 /mnt/extra-addons 2>/dev/null | grep -v "^\." | paste -sd, -' \
        2>/dev/null | tr -d '[:space:]' || true)"
fi

if [[ -z "${MODULES}" ]]; then
    log "no custom addons found in /mnt/extra-addons - nothing to test"
    log "SKIPPED (this is expected until the first custom module is added)"
    exit 0
fi

log "modules under test: ${MODULES}"

TEST_DB="test_$(date +%s)_$$"

cleanup() {
    log "dropping the throwaway test database ${TEST_DB}"
    # Terminate connections first, or DROP DATABASE is refused.
    psql_admin "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='${TEST_DB}'" >/dev/null 2>&1 || true
    psql_admin "DROP DATABASE IF EXISTS \\\"${TEST_DB}\\\"" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# --- Clone the environment database ----------------------------------------
# A template copy gives the tests realistic data without touching the source.
log "cloning ${ODOO_DB_NAME} into ${TEST_DB}"
psql_admin "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='${ODOO_DB_NAME}' AND pid <> pg_backend_pid()" >/dev/null 2>&1 || true

if ! psql_admin "CREATE DATABASE \\\"${TEST_DB}\\\" TEMPLATE \\\"${ODOO_DB_NAME}\\\"" >/dev/null 2>&1; then
    die "could not clone the database - is something still connected to ${ODOO_DB_NAME}?"
fi
log "clone created"

# --- Run the tests ---------------------------------------------------------
# --test-enable runs the suite; --stop-after-init exits afterwards instead of
# serving; --no-http keeps the throwaway instance off the network entirely.
log "running Odoo's test suite"
LOG_FILE="$(mktemp)"

if compose run --rm --no-deps -T odoo \
        odoo \
        --config=/etc/odoo/odoo.conf \
        --database="${TEST_DB}" \
        --update="${MODULES}" \
        --test-enable \
        --stop-after-init \
        --no-http \
        --log-level=test 2>&1 | tee "${LOG_FILE}"; then
    RUN_OK=1
else
    RUN_OK=0
fi

# Odoo has historically exited 0 while logging test failures, so the log is
# inspected as well as the exit status.
FAILED="$(grep -cE '^.*(FAIL|ERROR):' "${LOG_FILE}" || true)"
rm -f "${LOG_FILE}"

if (( RUN_OK == 1 )) && [[ "${FAILED}" == "0" ]]; then
    log "PASSED: no test failures for ${MODULES}"
    exit 0
fi

log "FAILED: exit_ok=${RUN_OK}, ${FAILED} FAIL/ERROR line(s) in the log"
exit 1
