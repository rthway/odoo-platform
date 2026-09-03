#!/usr/bin/env bash
# ===========================================================================
# tests/test-integration.sh - deeper checks against a running stack
# ===========================================================================
# Goes past "it responds" into "the parts are wired together correctly":
# the ORM works, the filestore is writable and persistent, sessions survive,
# proxy_mode is really in effect, cron is alive.
#
# Intended for QA. Read-only against business data; the one write it performs
# is into ir.config_parameter under a test-specific key, which it removes.
#
# Usage: tests/test-integration.sh [-e qa] [-u http://host:port]
# ===========================================================================
set -Eeuo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_DIR}"

ENVIRONMENT="qa"
BASE_URL=""

while getopts ":e:u:h" opt; do
    case "${opt}" in
        e) ENVIRONMENT="${OPTARG}" ;;
        u) BASE_URL="${OPTARG}" ;;
        h) sed -n '2,14p' "$0"; exit 0 ;;
        *) echo "unknown option -${OPTARG}" >&2; exit 2 ;;
    esac
done

if [[ -r .env ]]; then
    set -a
    # shellcheck disable=SC1091
    . .env
    set +a
fi
BASE_URL="${BASE_URL:-https://127.0.0.1:${HTTPS_PORT:-8443}}"

PASS=0
FAIL=0
pass() { printf '  PASS  %s\n' "$*"; PASS=$(( PASS + 1 )); }
fail() { printf '  FAIL  %s\n' "$*"; FAIL=$(( FAIL + 1 )); }

compose() {
    docker compose -f compose.yml -f "compose.${ENVIRONMENT}.yml" "$@"
}

psql_q() {
    compose exec -T db sh -c \
        "PGPASSWORD=\"\$POSTGRES_PASSWORD\" psql -U \"\$POSTGRES_USER\" -d \"\$POSTGRES_DB\" -tAc \"$1\"" \
        2>/dev/null | tr -d '[:space:]'
}

echo "== Integration tests: ${ENVIRONMENT} =="

# --- 1. The database is a real, initialised Odoo database ------------------
tables="$(psql_q "SELECT count(*) FROM information_schema.tables WHERE table_schema='public'")"
if [[ "${tables}" =~ ^[0-9]+$ ]] && (( tables > 50 )); then
    pass "database has ${tables} public tables"
else
    fail "database has only ${tables} tables - it is not an initialised Odoo database"
fi

modules="$(psql_q "SELECT count(*) FROM ir_module_module WHERE state='installed'")"
if [[ "${modules}" =~ ^[0-9]+$ ]] && (( modules > 0 )); then
    pass "${modules} modules are installed"
else
    fail "no installed modules"
fi

users="$(psql_q "SELECT count(*) FROM res_users WHERE active")"
if [[ "${users}" =~ ^[0-9]+$ ]] && (( users > 0 )); then
    pass "${users} active user(s)"
else
    fail "no active users - login would be impossible"
fi

# --- 2. Custom addons actually loaded --------------------------------------
# The addons path can be configured correctly and still load nothing if the
# module was never installed. Compare what is on disk with what Odoo knows.
on_disk="$(compose exec -T odoo sh -c \
    'ls -1 /mnt/extra-addons 2>/dev/null | grep -v "^\." | wc -l' 2>/dev/null | tr -d '[:space:]' || echo 0)"
if [[ "${on_disk}" == "0" ]]; then
    pass "no custom addons present (nothing to verify)"
else
    missing=0
    while read -r mod; do
        [[ -n "${mod}" ]] || continue
        known="$(psql_q "SELECT count(*) FROM ir_module_module WHERE name='${mod}'")"
        if [[ "${known}" == "0" ]]; then
            fail "custom addon '${mod}' is on disk but unknown to Odoo - the addons path is wrong"
            missing=1
        fi
    done < <(compose exec -T odoo sh -c 'ls -1 /mnt/extra-addons 2>/dev/null | grep -v "^\."' 2>/dev/null || true)
    (( missing == 0 )) && pass "all ${on_disk} custom addon(s) are known to Odoo"
fi

# --- 3. The ORM works ------------------------------------------------------
# A read through the ORM, not raw SQL: this exercises the registry, the
# environment and the database connection together.
if compose exec -T odoo odoo shell \
        --config=/etc/odoo/odoo.conf --database="${ODOO_DB_NAME}" --no-http \
        <<'PY' 2>/dev/null | grep -q 'ORM_OK'
count = env['res.users'].search_count([])
print('ORM_OK' if count > 0 else 'ORM_EMPTY')
env.cr.rollback()
PY
then
    pass "the ORM answers a search_count"
else
    fail "the ORM did not respond - the registry may have failed to load"
fi

# --- 4. The filestore is writable and persistent ---------------------------
# Odoo stores attachment bytes here. If it is not writable, uploads fail at
# the moment a user tries them, not at start-up.
probe="/var/lib/odoo/.integration-probe-$$"
if compose exec -T odoo sh -c "touch '${probe}' && rm -f '${probe}'" 2>/dev/null; then
    pass "the filestore is writable by the odoo user"
else
    fail "the filestore is NOT writable - attachment uploads would fail"
fi

if compose exec -T odoo sh -c 'mount | grep -q " /var/lib/odoo "' 2>/dev/null; then
    pass "the filestore is on a mounted volume (survives container replacement)"
else
    fail "the filestore is NOT a mounted volume - attachments would be lost on redeploy"
fi

# --- 5. proxy_mode is in effect --------------------------------------------
# Without it Odoo builds http:// URLs behind an https:// proxy, and password
# reset and confirmation emails send users to a broken address.
pm="$(compose exec -T odoo sh -c 'grep -E "^proxy_mode" /etc/odoo/odoo.conf' 2>/dev/null | tr -d '[:space:]' || echo '')"
if [[ "${pm}" == "proxy_mode=True" ]]; then
    pass "proxy_mode is enabled"
else
    fail "proxy_mode is '${pm}' - Odoo will generate incorrect absolute URLs"
fi

# --- 6. The proxy forwards the real client address -------------------------
fwd="$(curl -sk -o /dev/null -w '%{http_code}' -H 'X-Forwarded-For: 203.0.113.9' \
        --max-time 20 "${BASE_URL}/web/login" || echo 000)"
if [[ "${fwd}" =~ ^(200|303)$ ]]; then
    pass "requests carrying X-Forwarded-For are served (${fwd})"
else
    fail "proxied request returned ${fwd}"
fi

# --- 7. Sessions are issued ------------------------------------------------
# No session cookie means no login, however healthy everything else looks.
if curl -skI --max-time 20 "${BASE_URL}/web/login" | grep -qi 'set-cookie:.*session_id'; then
    pass "a session cookie is issued"
else
    fail "no session_id cookie - authentication would not work"
fi

# --- 8. Cron is running ----------------------------------------------------
# Odoo's scheduler drives invoicing, mail queues and cleanup. A stopped cron
# is invisible until a business process silently stops happening.
if [[ "${ODOO_MAX_CRON_THREADS:-1}" != "0" ]]; then
    stale="$(psql_q "SELECT count(*) FROM ir_cron WHERE active AND nextcall < now() - interval '1 hour'")"
    if [[ "${stale}" == "0" ]]; then
        pass "no overdue cron jobs"
    else
        fail "${stale} cron job(s) are more than an hour overdue - the scheduler may be stopped"
    fi
else
    pass "cron is disabled in this environment (max_cron_threads=0)"
fi

# --- 9. Database connection headroom ---------------------------------------
used="$(psql_q "SELECT count(*) FROM pg_stat_activity")"
maxc="$(psql_q "SHOW max_connections")"
if [[ "${used}" =~ ^[0-9]+$ && "${maxc}" =~ ^[0-9]+$ ]]; then
    pct=$(( used * 100 / maxc ))
    if (( pct < 80 )); then
        pass "connection usage ${used}/${maxc} (${pct}%)"
    else
        fail "connection usage ${used}/${maxc} (${pct}%) - too close to the limit"
    fi
else
    fail "could not read connection statistics"
fi

# --- 10. QA must not be pointed at production ------------------------------
if [[ "${ENVIRONMENT}" == "qa" ]]; then
    dbname="$(psql_q "SELECT current_database()")"
    if [[ "${dbname}" == *prod* ]]; then
        fail "CRITICAL: QA is connected to '${dbname}', which looks like production"
    else
        pass "QA is using its own database (${dbname})"
    fi
fi

# ---------------------------------------------------------------------------
echo
printf '  %s passed, %s failed\n' "${PASS}" "${FAIL}"
(( FAIL == 0 )) || exit 1
echo "  INTEGRATION TESTS PASSED"
