#!/usr/bin/env bash
# ===========================================================================
# scripts/healthcheck.sh - external verification that the stack really works
# ===========================================================================
# Docker reporting a container as "running" proves almost nothing: Odoo can
# be listening while its database is gone, nginx can be up while Odoo is not,
# and a container can be healthy for 20 seconds and then crash-loop.
#
# This script therefore checks, from OUTSIDE the containers:
#   1. every expected container exists and is running
#   2. no container is in a restart loop
#   3. PostgreSQL accepts a real query
#   4. Odoo answers /web/health over HTTP
#   5. Odoo answers a real application request (the login page renders)
#   6. nginx is serving
#
# Exit 0 = healthy, non-zero = do not promote / trigger rollback.
#
# Usage: scripts/healthcheck.sh [-e dev|qa|prod] [-t timeout] [-u url]
# ===========================================================================
set -Eeuo pipefail

ENVIRONMENT="${ENVIRONMENT:-dev}"
TIMEOUT="${HEALTHCHECK_TIMEOUT:-180}"
BASE_URL=""
COMPOSE_DIR="${COMPOSE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

usage() { sed -n '2,22p' "$0"; exit "${1:-0}"; }

while getopts ":e:t:u:h" opt; do
    case "${opt}" in
        e) ENVIRONMENT="${OPTARG}" ;;
        t) TIMEOUT="${OPTARG}" ;;
        u) BASE_URL="${OPTARG}" ;;
        h) usage 0 ;;
        *) echo "unknown option -${OPTARG}" >&2; usage 1 ;;
    esac
done

# --- Output helpers --------------------------------------------------------
if [[ -t 1 ]]; then
    C_OK=$'\033[32m'; C_BAD=$'\033[31m'; C_WARN=$'\033[33m'; C_OFF=$'\033[0m'
else
    C_OK=""; C_BAD=""; C_WARN=""; C_OFF=""
fi

FAILURES=0
pass() { printf '  %sPASS%s  %s\n' "${C_OK}"   "${C_OFF}" "$*"; }
fail() { printf '  %sFAIL%s  %s\n' "${C_BAD}"  "${C_OFF}" "$*"; FAILURES=$(( FAILURES + 1 )); }
warn() { printf '  %sWARN%s  %s\n' "${C_WARN}" "${C_OFF}" "$*"; }
head_() { printf '\n== %s\n' "$*"; }

# --- Compose invocation ----------------------------------------------------
compose() {
    docker compose \
        --project-directory "${COMPOSE_DIR}" \
        -f "${COMPOSE_DIR}/compose.yml" \
        -f "${COMPOSE_DIR}/compose.${ENVIRONMENT}.yml" \
        "$@"
}

# Load .env so PROJECT/PORT values match what was actually deployed.
if [[ -r "${COMPOSE_DIR}/.env" ]]; then
    set -a; . "${COMPOSE_DIR}/.env"; set +a
fi

if [[ -z "${BASE_URL}" ]]; then
    BASE_URL="http://127.0.0.1:${HTTP_PORT:-8080}"
fi

printf '=== Health check: environment=%s url=%s timeout=%ss ===\n' \
    "${ENVIRONMENT}" "${BASE_URL}" "${TIMEOUT}"

# ---------------------------------------------------------------------------
# 1. Containers exist and are running
# ---------------------------------------------------------------------------
head_ "Containers"
for svc in db odoo proxy; do
    cid="$(compose ps -q "${svc}" 2>/dev/null || true)"
    if [[ -z "${cid}" ]]; then
        fail "service '${svc}' has no container"
        continue
    fi
    state="$(docker inspect -f '{{.State.Status}}' "${cid}")"
    if [[ "${state}" == "running" ]]; then
        pass "${svc} is running (${cid:0:12})"
    else
        fail "${svc} is '${state}', expected 'running'"
    fi

    # 2. Restart loop detection. A container that has restarted repeatedly is
    #    not healthy no matter what its current status says.
    restarts="$(docker inspect -f '{{.RestartCount}}' "${cid}")"
    if (( restarts > 3 )); then
        fail "${svc} has restarted ${restarts} times - crash loop"
    elif (( restarts > 0 )); then
        warn "${svc} has restarted ${restarts} time(s)"
    fi

    # Docker's own healthcheck, where the image defines one.
    hs="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "${cid}")"
    case "${hs}" in
        healthy)   pass "${svc} docker healthcheck: healthy" ;;
        none)      : ;;
        starting)  warn "${svc} docker healthcheck: still starting" ;;
        *)         fail "${svc} docker healthcheck: ${hs}" ;;
    esac
done

# ---------------------------------------------------------------------------
# 3. PostgreSQL answers a real query
# ---------------------------------------------------------------------------
head_ "PostgreSQL"
if compose exec -T db sh -c \
        'PGPASSWORD="$POSTGRES_PASSWORD" psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "SELECT 1"' \
        2>/dev/null | grep -qx 1; then
    pass "accepts connections and answers SELECT 1"
    conns="$(compose exec -T db sh -c \
        'PGPASSWORD="$POSTGRES_PASSWORD" psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "SELECT count(*) FROM pg_stat_activity"' \
        2>/dev/null | tr -d '[:space:]' || echo '?')"
    pass "active backends: ${conns}"
else
    fail "PostgreSQL did not answer SELECT 1"
fi

# ---------------------------------------------------------------------------
# 4/5/6. HTTP, waiting up to TIMEOUT for Odoo to finish starting
# ---------------------------------------------------------------------------
head_ "HTTP"
deadline=$(( SECONDS + TIMEOUT ))
http_ok=0
while (( SECONDS < deadline )); do
    if curl -fsS -o /dev/null --max-time 10 "${BASE_URL}/web/health"; then
        http_ok=1
        break
    fi
    sleep 3
done

if (( http_ok == 1 )); then
    pass "/web/health responded (after $(( TIMEOUT - (deadline - SECONDS) ))s)"
else
    fail "/web/health did not respond within ${TIMEOUT}s"
fi

# A real application request. /web/health can be served before the ORM is
# ready; the login page rendering means Odoo actually loaded the registry.
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "${BASE_URL}/web/login" || echo 000)"
if [[ "${code}" =~ ^(200|303)$ ]]; then
    pass "/web/login returned HTTP ${code} - application registry is loaded"
else
    fail "/web/login returned HTTP ${code}, expected 200 or 303"
fi

# Response time, recorded so a slow-but-up deployment is still visible.
rt="$(curl -s -o /dev/null -w '%{time_total}' --max-time 20 "${BASE_URL}/web/login" || echo '?')"
pass "login page response time: ${rt}s"

# ---------------------------------------------------------------------------
head_ "Result"
if (( FAILURES == 0 )); then
    printf '%sHEALTHY%s - %s passed all checks\n' "${C_OK}" "${C_OFF}" "${ENVIRONMENT}"
    exit 0
fi
printf '%sUNHEALTHY%s - %s check(s) failed in %s\n' "${C_BAD}" "${C_OFF}" "${FAILURES}" "${ENVIRONMENT}"
exit 1
