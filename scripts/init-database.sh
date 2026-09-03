#!/usr/bin/env bash
# ===========================================================================
# scripts/init-database.sh - one-time bootstrap of a new environment
# ===========================================================================
# A freshly created PostgreSQL database has no Odoo schema. Odoo starts, but
# every request fails with KeyError: 'ir.http' and the proxy returns 500 -
# which reads like a broken deployment rather than an empty database.
#
# deploy.sh deliberately does not do this. Deploying an image and creating
# data are different operations with different risks, and a deployment script
# that quietly initialises a database is one that can quietly initialise the
# WRONG database.
#
# This script is:
#   - idempotent: it detects an existing Odoo schema and exits without
#     touching it, so a second run cannot damage a live environment
#   - refused on production unless --i-am-bootstrapping-production is passed,
#     because production is normally seeded by restoring a backup, not by
#     creating an empty database
#
# Usage:
#   scripts/init-database.sh -e dev -t 2026.09.03-a1b2c3d
#   scripts/init-database.sh -e qa -m base,web
# ===========================================================================
set -Eeuo pipefail

ENVIRONMENT=""
MODULES="base"
IMAGE_TAG_OPT=""
CONFIRM_PROD=0
COMPOSE_DIR="${COMPOSE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -e|--environment) ENVIRONMENT="$2"; shift 2 ;;
        -m|--modules)     MODULES="$2"; shift 2 ;;
        -t|--tag)         IMAGE_TAG_OPT="$2"; shift 2 ;;
        --i-am-bootstrapping-production) CONFIRM_PROD=1; shift ;;
        -h|--help)        sed -n '2,24p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

log() { printf '%s [init-db] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die() { printf '%s [init-db] FATAL: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; exit 1; }

[[ -n "${ENVIRONMENT}" ]] || die "-e dev|qa|prod is required"

[[ -r "${COMPOSE_DIR}/.env" ]] || die "${COMPOSE_DIR}/.env is missing"
set -a
# shellcheck disable=SC1091
. "${COMPOSE_DIR}/.env"
set +a

: "${ODOO_DB_NAME:?ODOO_DB_NAME is required}"

# The image tag is a property of the deployment, so .env may not carry one
# yet on a host that has never had a successful deployment - which is exactly
# when this script runs. Take it from -t, then from .env, then from the
# recorded deployment state.
if [[ -n "${IMAGE_TAG_OPT}" ]]; then
    ODOO_IMAGE_TAG="${IMAGE_TAG_OPT}"
elif [[ -z "${ODOO_IMAGE_TAG:-}" && -r "${COMPOSE_DIR}/.deploy-state/current" ]]; then
    ODOO_IMAGE_TAG="$(cat "${COMPOSE_DIR}/.deploy-state/current")"
fi
[[ -n "${ODOO_IMAGE_TAG:-}" ]] \
    || die "no image tag. Pass -t <tag>, or deploy once first - compose cannot start a service without one."
export ODOO_IMAGE_TAG

compose() {
    docker compose --project-directory "${COMPOSE_DIR}" \
        -f "${COMPOSE_DIR}/compose.yml" \
        -f "${COMPOSE_DIR}/compose.${ENVIRONMENT}.yml" "$@"
}

# ---------------------------------------------------------------------------
# Guard rails
# ---------------------------------------------------------------------------
if [[ "${ENVIRONMENT}" == "prod" && "${CONFIRM_PROD}" -ne 1 ]]; then
    die "refusing to initialise production. Production is normally seeded by restoring a backup (scripts/restore.sh). If this really is a greenfield production database, pass --i-am-bootstrapping-production"
fi

log "environment : ${ENVIRONMENT}"
log "database    : ${ODOO_DB_NAME}"
log "modules     : ${MODULES}"

# ---------------------------------------------------------------------------
# Is it already initialised?
# ---------------------------------------------------------------------------
# ir_module_module exists in every Odoo database and in no empty one, so its
# presence is a reliable test. Checking is what makes a second run harmless.
log "checking whether the database already has an Odoo schema"
existing="$(compose exec -T db sh -c \
    "PGPASSWORD=\"\$POSTGRES_PASSWORD\" psql -U \"\$POSTGRES_USER\" -d \"${ODOO_DB_NAME}\" -tAc \"SELECT to_regclass('public.ir_module_module') IS NOT NULL\"" \
    2>/dev/null | tr -d '[:space:]' || echo 'error')"

if [[ "${existing}" == "error" ]]; then
    die "could not query ${ODOO_DB_NAME}. Is the stack running? Try: docker compose ps"
fi

if [[ "${existing}" == "t" ]]; then
    installed="$(compose exec -T db sh -c \
        "PGPASSWORD=\"\$POSTGRES_PASSWORD\" psql -U \"\$POSTGRES_USER\" -d \"${ODOO_DB_NAME}\" -tAc \"SELECT count(*) FROM ir_module_module WHERE state='installed'\"" \
        2>/dev/null | tr -d '[:space:]')"
    log "already initialised: ${installed} module(s) installed"
    log "nothing to do. To CHANGE modules use scripts/migrate.sh, which is designed for it."
    exit 0
fi

log "database is empty - initialising"

# ---------------------------------------------------------------------------
# Initialise
# ---------------------------------------------------------------------------
# A one-off container with --stop-after-init, and --no-http so the instance
# cannot serve a request mid-initialisation. Odoo must NOT be serving while
# this runs, or it races to create the same registry.
log "stopping Odoo so it cannot race the initialisation"
compose stop odoo >/dev/null 2>&1 || true

START="$(date -u +%s)"
log "running odoo --init=${MODULES} (this takes a few minutes)"

if ! compose run --rm --no-deps -T odoo \
        odoo --config=/etc/odoo/odoo.conf \
             --database="${ODOO_DB_NAME}" \
             --init="${MODULES}" \
             --stop-after-init \
             --no-http; then
    die "initialisation FAILED. The database may be partially created; drop it and retry rather than deploying on top of it."
fi

log "initialised in $(( $(date -u +%s) - START ))s"

# ---------------------------------------------------------------------------
# Verify, then start
# ---------------------------------------------------------------------------
tables="$(compose exec -T db sh -c \
    "PGPASSWORD=\"\$POSTGRES_PASSWORD\" psql -U \"\$POSTGRES_USER\" -d \"${ODOO_DB_NAME}\" -tAc \"SELECT count(*) FROM information_schema.tables WHERE table_schema='public'\"" \
    2>/dev/null | tr -d '[:space:]')"
[[ "${tables}" =~ ^[0-9]+$ && "${tables}" -gt 50 ]] \
    || die "only ${tables} tables were created - initialisation did not complete"
log "schema created: ${tables} tables"

log "starting the stack"
compose up -d

log "running health checks"
"${COMPOSE_DIR}/scripts/healthcheck.sh" -e "${ENVIRONMENT}" \
    || die "initialised, but the environment is not healthy"

log "SUCCESS: ${ODOO_DB_NAME} initialised and ${ENVIRONMENT} is healthy"
log "The Odoo master password is ODOO_ADMIN_PASSWD in .env; the default login is admin."
