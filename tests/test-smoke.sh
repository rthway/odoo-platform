#!/usr/bin/env bash
# ===========================================================================
# tests/test-smoke.sh - fast checks against a RUNNING stack
# ===========================================================================
# Answers "is this deployment actually usable?" rather than "did containers
# start?". Run after every deployment, in every environment.
#
# Requires: a running stack. Read-only - creates nothing, changes nothing.
#
# Usage: tests/test-smoke.sh [-e dev|qa|prod] [-u http://host:port]
# ===========================================================================
set -Eeuo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_DIR}"

ENVIRONMENT="${ENVIRONMENT:-dev}"
BASE_URL=""

while getopts ":e:u:h" opt; do
    case "${opt}" in
        e) ENVIRONMENT="${OPTARG}" ;;
        u) BASE_URL="${OPTARG}" ;;
        h) sed -n '2,12p' "$0"; exit 0 ;;
        *) echo "unknown option -${OPTARG}" >&2; exit 2 ;;
    esac
done

if [[ -r .env ]]; then
    set -a
    # shellcheck disable=SC1091
    . .env
    set +a
fi
# HTTPS by default; HTTP only ever returns the redirect.
BASE_URL="${BASE_URL:-https://127.0.0.1:${HTTPS_PORT:-8443}}"

PASS=0
FAIL=0
pass() { printf '  PASS  %s\n' "$*"; PASS=$(( PASS + 1 )); }
fail() { printf '  FAIL  %s\n' "$*"; FAIL=$(( FAIL + 1 )); }

compose() {
    docker compose -f compose.yml -f "compose.${ENVIRONMENT}.yml" "$@"
}

code_for() { curl -sk -o /dev/null -w '%{http_code}' --max-time 20 "$1" || echo 000; }

echo "== Smoke tests: ${ENVIRONMENT} at ${BASE_URL} =="

# --- 1. Health endpoint ----------------------------------------------------
c="$(code_for "${BASE_URL}/web/health")"
[[ "${c}" == "200" ]] && pass "/web/health returns 200" || fail "/web/health returned ${c}"

# --- 2. The login page renders --------------------------------------------
# This is the real test of "Odoo is up": /web/health can answer before the
# ORM registry has finished loading.
c="$(code_for "${BASE_URL}/web/login")"
if [[ "${c}" =~ ^(200|303)$ ]]; then
    pass "/web/login returns ${c}"
else
    fail "/web/login returned ${c}"
fi

# --- 3. The page is really Odoo, not an error page from the proxy ----------
body="$(curl -sk --max-time 20 "${BASE_URL}/web/login" || echo '')"
if grep -qiE 'odoo|<form|csrf_token' <<<"${body}"; then
    pass "the login page contains real Odoo markup"
else
    fail "the login response does not look like Odoo's login page"
fi

# --- 4. Static assets are served ------------------------------------------
c="$(code_for "${BASE_URL}/web/static/img/favicon.ico")"
if [[ "${c}" =~ ^(200|304)$ ]]; then
    pass "static assets are served (${c})"
else
    fail "static asset request returned ${c}"
fi

# --- 5. The database manager must be unreachable outside dev ---------------
c="$(code_for "${BASE_URL}/web/database/manager")"
if [[ "${ENVIRONMENT}" == "dev" ]]; then
    pass "database manager returns ${c} (permitted in dev)"
elif [[ "${c}" == "200" ]]; then
    fail "SECURITY: the database manager is exposed in ${ENVIRONMENT} (HTTP 200)"
else
    pass "database manager is blocked in ${ENVIRONMENT} (${c})"
fi

# --- 6. Security headers ---------------------------------------------------
headers="$(curl -skI --max-time 20 "${BASE_URL}/web/login" || echo '')"
for h in x-content-type-options x-frame-options referrer-policy; do
    if grep -qi "^${h}:" <<<"${headers}"; then
        pass "response carries ${h}"
    else
        fail "response is missing ${h}"
    fi
done

# nginx must not advertise its version.
if grep -qiE '^server: nginx/[0-9]' <<<"${headers}"; then
    fail "nginx is leaking its version in the Server header"
else
    pass "no nginx version is advertised"
fi

# --- 7. PostgreSQL answers -------------------------------------------------
if compose exec -T db sh -c \
        'PGPASSWORD="$POSTGRES_PASSWORD" psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "SELECT 1"' \
        2>/dev/null | grep -qx 1; then
    pass "PostgreSQL answers SELECT 1"
else
    fail "PostgreSQL did not answer"
fi

# --- 8. Odoo is connected to its database ----------------------------------
# Confirms Odoo has an open connection, which distinguishes "Odoo is running"
# from "Odoo is running and can actually serve data".
backends="$(compose exec -T db sh -c \
    'PGPASSWORD="$POSTGRES_PASSWORD" psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "SELECT count(*) FROM pg_stat_activity WHERE datname = current_database()"' \
    2>/dev/null | tr -d '[:space:]' || echo 0)"
if [[ "${backends}" =~ ^[0-9]+$ ]] && (( backends > 0 )); then
    pass "Odoo holds ${backends} database connection(s)"
else
    fail "no application connections to the database"
fi

# --- 9. No container is restarting -----------------------------------------
for svc in db odoo proxy; do
    cid="$(compose ps -q "${svc}" 2>/dev/null || true)"
    if [[ -z "${cid}" ]]; then
        fail "${svc} has no container"
        continue
    fi
    # RestartCount is a top-level field of the container object, not part of
    # .State. `{{.State.RestartCount}}` is not merely empty - it aborts the
    # whole command with a template error.
    restarts="$(docker inspect -f '{{.RestartCount}}' "${cid}")"
    if (( restarts > 3 )); then
        fail "${svc} has restarted ${restarts} times"
    else
        pass "${svc} is stable (${restarts} restarts)"
    fi
done

# --- 10. No errors in recent application logs ------------------------------
# A TIME window, not `--tail 200`. The question a smoke test needs to answer
# is "is this deployment erroring now?", and a line count cannot answer it:
# after a quiet period the last 200 lines still contain whatever went wrong
# hours ago, so the check fails on problems that are already fixed. That is
# exactly what happened on the first DEV deployment - the pre-initialisation
# tracebacks kept failing the smoke test long after the database was fixed.
#
# Match on Odoo's LOG LEVEL, not on the word "Traceback". Odoo logs handled
# exceptions with a full traceback at DEBUG - a browser presenting a stale
# session cookie produces one every request - so counting the word reports
# failures for behaviour that is working exactly as intended. DEV runs at
# debug level, so it saw 22 of these from a single visitor.
#
# Odoo's format is: <timestamp> <pid> <LEVEL> <db> <logger>: <message>
LOG_WINDOW="${SMOKE_LOG_WINDOW:-5m}"
errors="$(compose logs --since "${LOG_WINDOW}" odoo 2>/dev/null     | grep -cE '[0-9]{2}:[0-9]{2}:[0-9]{2},[0-9]{3} [0-9]+ (CRITICAL|ERROR) ' || true)"
if [[ "${errors}" == "0" ]]; then
    pass "no ERROR or CRITICAL entries in the last ${LOG_WINDOW}"
else
    fail "${errors} ERROR/CRITICAL line(s) in the last ${LOG_WINDOW} of Odoo logs"
    compose logs --since "${LOG_WINDOW}" odoo 2>/dev/null         | grep -E '[0-9]{2}:[0-9]{2}:[0-9]{2},[0-9]{3} [0-9]+ (CRITICAL|ERROR) '         | tail -3 | sed 's/^/          /'
fi

# ---------------------------------------------------------------------------
echo
printf '  %s passed, %s failed\n' "${PASS}" "${FAIL}"
(( FAIL == 0 )) || exit 1
echo "  SMOKE TESTS PASSED"
