#!/usr/bin/env bash
# ===========================================================================
# scripts/restore.sh - restore a backup set into an environment
# ===========================================================================
# THIS SCRIPT DESTROYS THE TARGET DATABASE AND FILESTORE.
#
# It is deliberately awkward to run:
#   - it refuses ENVIRONMENT=prod unless --i-understand-this-destroys-prod
#     is passed AND the operator types the database name when prompted
#   - it takes a safety backup of the CURRENT state first, so a restore that
#     turns out to be the wrong backup set is itself recoverable
#   - it verifies the backup BEFORE touching anything
#   - it stops Odoo first: restoring underneath a running Odoo produces a
#     corrupt registry and a filestore that disagrees with the database
#
# Usage:
#   scripts/restore.sh -e qa   -s /var/backups/odoo/prod/20260903T010000Z_daily
#   scripts/restore.sh -e prod -s <set> --i-understand-this-destroys-prod
# ===========================================================================
set -Eeuo pipefail

ENVIRONMENT="qa"
SET_DIR=""
CONFIRM_PROD=0
SKIP_SAFETY=0
COMPOSE_DIR="${COMPOSE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -e|--environment) ENVIRONMENT="$2"; shift 2 ;;
        -s|--set)         SET_DIR="$2"; shift 2 ;;
        --i-understand-this-destroys-prod) CONFIRM_PROD=1; shift ;;
        # Only for restoring into a scratch environment that has nothing worth
        # preserving. Never use this against prod.
        --skip-safety-backup) SKIP_SAFETY=1; shift ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

log()  { printf '%s [restore] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die()  { printf '%s [restore] FATAL: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; exit 1; }

[[ -n "${SET_DIR}" ]] || die "-s <backup-set-dir> is required"
[[ -d "${SET_DIR}" ]] || die "no such backup set: ${SET_DIR}"

if [[ -r "${COMPOSE_DIR}/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    . "${COMPOSE_DIR}/.env"
    set +a
fi

: "${POSTGRES_USER:?POSTGRES_USER is required}"
: "${POSTGRES_DB:?POSTGRES_DB is required}"

compose() {
    docker compose --project-directory "${COMPOSE_DIR}" \
        -f "${COMPOSE_DIR}/compose.yml" \
        -f "${COMPOSE_DIR}/compose.${ENVIRONMENT}.yml" "$@"
}

# ---------------------------------------------------------------------------
# Guard rails
# ---------------------------------------------------------------------------
cat <<BANNER

  ####################################################################
  #  DESTRUCTIVE OPERATION                                           #
  #                                                                  #
  #  Environment : ${ENVIRONMENT}
  #  Database    : ${POSTGRES_DB}
  #  Backup set  : ${SET_DIR}
  #                                                                  #
  #  The current database and filestore will be REPLACED.            #
  ####################################################################

BANNER

if [[ "${ENVIRONMENT}" == "prod" ]]; then
    (( CONFIRM_PROD == 1 )) \
        || die "refusing to restore production without --i-understand-this-destroys-prod"
    (( SKIP_SAFETY == 0 )) \
        || die "--skip-safety-backup is not permitted against production"

    # Interactive second gate. In a non-interactive context (CI, cron) there
    # is no stdin, so this fails closed - which is the correct behaviour.
    [[ -t 0 ]] || die "production restore requires an interactive terminal"
    printf 'Type the production database name (%s) to proceed: ' "${POSTGRES_DB}"
    read -r typed
    [[ "${typed}" == "${POSTGRES_DB}" ]] || die "confirmation did not match - aborted"
fi

# ---------------------------------------------------------------------------
# 1. Verify the backup BEFORE destroying anything
# ---------------------------------------------------------------------------
log "verifying backup integrity before proceeding"
"${COMPOSE_DIR}/scripts/verify-backup.sh" -s "${SET_DIR}" --checksums \
    || die "backup failed verification - refusing to restore from a damaged set"

DUMP="${SET_DIR}/database.dump"
FS="${SET_DIR}/filestore.tar.gz"
TMP_PLAIN=""

if [[ ! -f "${DUMP}" && -f "${DUMP}.age" ]]; then
    command -v age >/dev/null 2>&1 || die "backup is encrypted but 'age' is not installed"
    [[ -n "${BACKUP_AGE_IDENTITY:-}" ]] \
        || die "set BACKUP_AGE_IDENTITY to the age private key file"
    TMP_PLAIN="$(mktemp -d)"
    trap 'rm -rf "${TMP_PLAIN}"' EXIT
    log "decrypting backup set"
    age -d -i "${BACKUP_AGE_IDENTITY}" -o "${TMP_PLAIN}/database.dump"   "${DUMP}.age" || die "dump decryption failed"
    age -d -i "${BACKUP_AGE_IDENTITY}" -o "${TMP_PLAIN}/filestore.tar.gz" "${FS}.age"  || die "filestore decryption failed"
    DUMP="${TMP_PLAIN}/database.dump"
    FS="${TMP_PLAIN}/filestore.tar.gz"
fi

[[ -f "${DUMP}" ]] || die "database.dump not found in backup set"

# ---------------------------------------------------------------------------
# 2. Safety backup of the CURRENT state
# ---------------------------------------------------------------------------
# Restoring the wrong backup set is a routine human error. Without this step
# that mistake is unrecoverable.
if (( SKIP_SAFETY == 0 )); then
    log "taking a safety backup of the current state before overwriting it"
    SAFETY="$("${COMPOSE_DIR}/scripts/backup.sh" -e "${ENVIRONMENT}" -l pre-restore | tail -1)" \
        || die "safety backup failed - refusing to continue"
    log "safety backup written to ${SAFETY}"
else
    log "WARNING: safety backup skipped by request"
fi

# ---------------------------------------------------------------------------
# 3. Stop Odoo (but leave PostgreSQL running - we restore into it)
# ---------------------------------------------------------------------------
log "stopping Odoo so nothing writes during the restore"
compose stop odoo proxy || die "could not stop application containers"

# ---------------------------------------------------------------------------
# 4. Restore the database
# ---------------------------------------------------------------------------
# Terminate leftover backends first: PostgreSQL refuses to drop a database
# that still has connections, and Odoo's pool can outlive the container stop.
log "terminating existing connections to ${POSTGRES_DB}"
compose exec -T db sh -c "PGPASSWORD=\"\$POSTGRES_PASSWORD\" psql -U \"\$POSTGRES_USER\" -d postgres -c \
    \"SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='${POSTGRES_DB}' AND pid <> pg_backend_pid()\"" \
    >/dev/null || log "WARNING: could not terminate all backends"

log "recreating database ${POSTGRES_DB}"
compose exec -T db sh -c "PGPASSWORD=\"\$POSTGRES_PASSWORD\" psql -U \"\$POSTGRES_USER\" -d postgres -c \
    'DROP DATABASE IF EXISTS \"${POSTGRES_DB}\"'" >/dev/null || die "DROP DATABASE failed"
compose exec -T db sh -c "PGPASSWORD=\"\$POSTGRES_PASSWORD\" psql -U \"\$POSTGRES_USER\" -d postgres -c \
    'CREATE DATABASE \"${POSTGRES_DB}\" OWNER \"${POSTGRES_USER}\"'" >/dev/null || die "CREATE DATABASE failed"

log "restoring dump (parallel where possible)"
RESTORE_START="$(date -u +%s)"
compose exec -T db sh -c \
    "PGPASSWORD=\"\$POSTGRES_PASSWORD\" pg_restore -U \"\$POSTGRES_USER\" -d \"${POSTGRES_DB}\" \
     --no-owner --no-acl --exit-on-error --jobs=4" \
    < "${DUMP}" || die "pg_restore FAILED - database is in an incomplete state, see docs/disaster-recovery.md"
log "database restored in $(( $(date -u +%s) - RESTORE_START ))s"

# ---------------------------------------------------------------------------
# 5. Restore the filestore
# ---------------------------------------------------------------------------
# Without this the database references attachments whose bytes do not exist,
# and every document in the system 404s.
if [[ -f "${FS}" ]]; then
    log "restoring filestore"
    compose run --rm --no-deps -T --entrypoint sh odoo -c \
        'rm -rf /var/lib/odoo/* && tar -xzf - -C /var/lib/odoo' < "${FS}" \
        || die "filestore restore FAILED - attachments will be broken"
    log "filestore restored"
else
    log "WARNING: no filestore archive in this set - attachments will be missing"
fi

# ---------------------------------------------------------------------------
# 6. Restart and verify
# ---------------------------------------------------------------------------
log "starting the stack"
compose up -d || die "stack did not start after restore"

log "running health checks"
if "${COMPOSE_DIR}/scripts/healthcheck.sh" -e "${ENVIRONMENT}"; then
    log "SUCCESS: restore complete and ${ENVIRONMENT} is healthy"
else
    die "restore completed but health checks FAILED - investigate before serving traffic"
fi
