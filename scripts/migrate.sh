#!/usr/bin/env bash
# ===========================================================================
# scripts/migrate.sh - run Odoo module updates (schema migration)
# ===========================================================================
# This is the most dangerous routine operation in an Odoo platform.
#
# `odoo -u <module>` rewrites the schema: it adds and drops columns, converts
# field types and transforms stored data. It is ONE-WAY. There is no
# `odoo --downgrade`. The only route back is restoring a pre-migration
# backup, which discards everything committed since.
#
# So this script:
#   1. refuses to run against production without a verified fresh backup
#   2. stops Odoo first - migrating under live traffic corrupts the registry
#   3. runs with --stop-after-init so the process exits instead of serving
#   4. treats any migration error as fatal and leaves the stack stopped,
#      because a half-migrated database serving users is far worse than an
#      outage with an intact backup
#
# Usage:
#   scripts/migrate.sh -e qa   -m all
#   scripts/migrate.sh -e prod -m sale,stock --backup-set <dir>
# ===========================================================================
set -Eeuo pipefail

ENVIRONMENT=""
MODULES="all"
BACKUP_SET=""
COMPOSE_DIR="${COMPOSE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -e|--environment) ENVIRONMENT="$2"; shift 2 ;;
        -m|--modules)     MODULES="$2"; shift 2 ;;
        --backup-set)     BACKUP_SET="$2"; shift 2 ;;
        -h|--help)        sed -n '2,24p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

log() { printf '%s [migrate] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die() { printf '%s [migrate] FATAL: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; exit 1; }

[[ -n "${ENVIRONMENT}" ]] || die "-e dev|qa|prod is required"

[[ -r "${COMPOSE_DIR}/.env" ]] || die "${COMPOSE_DIR}/.env is missing"
set -a
# shellcheck disable=SC1091
. "${COMPOSE_DIR}/.env"
set +a

: "${ODOO_DB_NAME:?ODOO_DB_NAME is required}"

compose() {
    docker compose --project-directory "${COMPOSE_DIR}" \
        -f "${COMPOSE_DIR}/compose.yml" \
        -f "${COMPOSE_DIR}/compose.${ENVIRONMENT}.yml" "$@"
}

log "environment : ${ENVIRONMENT}"
log "database    : ${ODOO_DB_NAME}"
log "modules     : ${MODULES}"

# ---------------------------------------------------------------------------
# 1. Production requires a verified, fresh backup
# ---------------------------------------------------------------------------
if [[ "${ENVIRONMENT}" == "prod" ]]; then
    if [[ -z "${BACKUP_SET}" ]]; then
        log "no --backup-set given; taking one now"
        BACKUP_SET="$("${COMPOSE_DIR}/scripts/backup.sh" -e prod -l pre-migration | tail -1)" \
            || die "pre-migration backup failed - refusing to migrate production"
    fi

    [[ -d "${BACKUP_SET}" ]] || die "backup set ${BACKUP_SET} does not exist"

    log "verifying the backup before migrating"
    "${COMPOSE_DIR}/scripts/verify-backup.sh" -s "${BACKUP_SET}" --checksums \
        || die "backup failed verification - refusing to migrate production"

    # A backup taken hours ago is not a rollback point for a migration that
    # runs now: every transaction in between would be lost.
    backup_epoch="$(stat -c %Y "${BACKUP_SET}")"
    age_minutes=$(( ( $(date +%s) - backup_epoch ) / 60 ))
    if (( age_minutes > 60 )); then
        die "backup is ${age_minutes} minutes old - take a fresh one before migrating production"
    fi
    log "backup verified and ${age_minutes} minutes old: ${BACKUP_SET}"
fi

# ---------------------------------------------------------------------------
# 2. Stop the application
# ---------------------------------------------------------------------------
# Odoo caches the registry in memory. Migrating while workers are live gives
# some workers the old schema and some the new one.
log "stopping Odoo and the proxy (this begins the maintenance window)"
compose stop odoo proxy || die "could not stop the application"

MIGRATION_START="$(date -u +%s)"

# ---------------------------------------------------------------------------
# 3. Run the migration
# ---------------------------------------------------------------------------
# --stop-after-init makes this a batch job: Odoo updates the modules and
# exits, rather than staying up and accepting traffic mid-migration.
# --no-http removes any chance of serving a request during the update.
log "running module update - DO NOT INTERRUPT"
if compose run --rm --no-deps -T odoo \
        odoo \
        --config=/etc/odoo/odoo.conf \
        --database="${ODOO_DB_NAME}" \
        --update="${MODULES}" \
        --stop-after-init \
        --no-http \
        --log-level="${MIGRATION_LOG_LEVEL:-info}"; then
    MIGRATION_SECONDS=$(( $(date -u +%s) - MIGRATION_START ))
    log "migration completed in ${MIGRATION_SECONDS}s"
else
    cat <<'FAILED' >&2

  ##################################################################
  #  MIGRATION FAILED                                              #
  #                                                                #
  #  The application has NOT been restarted. The database may be   #
  #  partially migrated.                                           #
  #                                                                #
  #  DO NOT start Odoo and DO NOT let users in.                    #
  #                                                                #
  #  Odoo wraps a module update in a transaction, so it usually    #
  #  rolls back cleanly - but "usually" is not a guarantee.        #
  #  Verify the schema, or restore the pre-migration backup, per   #
  #  docs/disaster-recovery.md.                                    #
  ##################################################################

FAILED
    [[ -n "${BACKUP_SET}" ]] && echo "  Pre-migration backup: ${BACKUP_SET}" >&2
    die "module update failed for: ${MODULES}"
fi

# ---------------------------------------------------------------------------
# 4. Restart and verify
# ---------------------------------------------------------------------------
log "restarting the stack"
compose up -d || die "stack failed to start after a successful migration - investigate immediately"

log "running health checks"
"${COMPOSE_DIR}/scripts/healthcheck.sh" -e "${ENVIRONMENT}" \
    || die "migration succeeded but the application is unhealthy - see docs/incident-response.md"

# ---------------------------------------------------------------------------
# 5. Record it
# ---------------------------------------------------------------------------
STATE_DIR="${COMPOSE_DIR}/.deploy-state"
mkdir -p "${STATE_DIR}"
printf '%s MIGRATION env=%s modules=%s duration=%ss backup=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${ENVIRONMENT}" "${MODULES}" \
    "${MIGRATION_SECONDS}" "${BACKUP_SET:-none}" >> "${STATE_DIR}/history.log"

log "SUCCESS: modules updated and ${ENVIRONMENT} is healthy"
log "REMINDER: the schema is now migrated. An image rollback alone will not undo it."
