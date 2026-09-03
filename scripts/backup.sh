#!/usr/bin/env bash
# ===========================================================================
# scripts/backup.sh - PostgreSQL + Odoo filestore backup
# ===========================================================================
# An Odoo backup is TWO things that must be taken together:
#   1. the PostgreSQL database (records, and the filestore *references*)
#   2. the filestore on disk (the actual attachment bytes)
# Restoring one without the other gives a database full of broken documents.
#
# Ordering matters. The filestore is captured FIRST, then the database. Odoo
# writes the file before committing the row, so a file with no row is
# harmless garbage, whereas a row with no file is a broken attachment.
#
# Every backup writes a manifest with SHA-256 checksums so verify-backup.sh
# can prove the archive is intact without restoring it.
#
# Usage: scripts/backup.sh [-e dev|qa|prod] [-d /var/backups/odoo] [-l daily]
# ===========================================================================
set -Eeuo pipefail

ENVIRONMENT="${ENVIRONMENT:-prod}"
LABEL="manual"
COMPOSE_DIR="${COMPOSE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
BACKUP_DIR_OPT=""

while getopts ":e:d:l:h" opt; do
    case "${opt}" in
        e) ENVIRONMENT="${OPTARG}" ;;
        d) BACKUP_DIR_OPT="${OPTARG}" ;;
        l) LABEL="${OPTARG}" ;;
        h) sed -n '2,18p' "$0"; exit 0 ;;
        *) echo "unknown option -${OPTARG}" >&2; exit 2 ;;
    esac
done

log() { printf '%s [backup] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die() { printf '%s [backup] FATAL: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; exit 1; }

if [[ -r "${COMPOSE_DIR}/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    . "${COMPOSE_DIR}/.env"
    set +a
fi

# -d wins over .env, which wins over the default.
BACKUP_DIR="${BACKUP_DIR_OPT:-${BACKUP_DIR:-/var/backups/odoo}}"

compose() {
    docker compose --project-directory "${COMPOSE_DIR}" \
        -f "${COMPOSE_DIR}/compose.yml" \
        -f "${COMPOSE_DIR}/compose.${ENVIRONMENT}.yml" "$@"
}

: "${POSTGRES_USER:?POSTGRES_USER is required}"
: "${POSTGRES_DB:?POSTGRES_DB is required}"

TS="$(date -u +%Y%m%dT%H%M%SZ)"
SET_DIR="${BACKUP_DIR}/${ENVIRONMENT}/${TS}_${LABEL}"
DB_FILE="${SET_DIR}/database.dump"
FS_FILE="${SET_DIR}/filestore.tar.gz"
CFG_FILE="${SET_DIR}/config.tar.gz"
MANIFEST="${SET_DIR}/manifest.json"

# --- Pre-flight ------------------------------------------------------------
# Check free space BEFORE starting. A backup that fills the disk takes the
# production database down with it, turning a routine job into an outage.
mkdir -p "${SET_DIR}"

db_size_bytes="$(compose exec -T db sh -c \
    'PGPASSWORD="$POSTGRES_PASSWORD" psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "SELECT pg_database_size(current_database())"' \
    2>/dev/null | tr -d '[:space:]' || echo 0)"
: "${db_size_bytes:=0}"

avail_kb="$(df -Pk "${BACKUP_DIR}" | awk 'NR==2 {print $4}')"
# Twice the database size (dump plus headroom) plus 1GB for the filestore.
need_kb=$(( (db_size_bytes / 1024) * 2 + 1048576 ))
if (( avail_kb < need_kb )); then
    die "insufficient space in ${BACKUP_DIR}: ${avail_kb}KB free, need ~${need_kb}KB"
fi
log "pre-flight OK: ${avail_kb}KB free, database is $(( db_size_bytes / 1048576 ))MB"

START_EPOCH="$(date -u +%s)"

# --- 1. Filestore (first, see header) --------------------------------------
log "archiving Odoo filestore"
compose exec -T odoo tar -czf - -C /var/lib/odoo . > "${FS_FILE}" \
    || die "filestore archive failed"
log "filestore: $(du -h "${FS_FILE}" | cut -f1)"

# --- 2. Database -----------------------------------------------------------
# Custom format (-Fc): compressed, and restorable selectively or in parallel
# with pg_restore. A plain SQL dump can do neither.
log "dumping database ${POSTGRES_DB}"
compose exec -T db sh -c \
    'PGPASSWORD="$POSTGRES_PASSWORD" pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc --no-owner --no-acl' \
    > "${DB_FILE}" || die "pg_dump failed"

# A dump that exists but is empty or truncated is worse than no dump, because
# it creates false confidence. Confirm it is a real custom-format archive.
[[ -s "${DB_FILE}" ]] || die "database dump is empty"
head -c 5 "${DB_FILE}" | grep -q 'PGDMP' \
    || die "dump lacks the PGDMP header - not a valid custom-format dump"
log "database: $(du -h "${DB_FILE}" | cut -f1)"

# --- 3. Configuration ------------------------------------------------------
# So a rebuild during an incident does not depend on GitHub being reachable.
# .env is excluded deliberately: it holds secrets and belongs in Ansible.
log "archiving configuration"
tar -czf "${CFG_FILE}" -C "${COMPOSE_DIR}" \
    --exclude='.env' \
    compose.yml "compose.${ENVIRONMENT}.yml" config 2>/dev/null \
    || log "WARNING: configuration archive incomplete"

# --- 4. Encryption ---------------------------------------------------------
if [[ -n "${BACKUP_AGE_RECIPIENT:-}" ]]; then
    command -v age >/dev/null 2>&1 \
        || die "BACKUP_AGE_RECIPIENT set but 'age' is missing - refusing to write an unencrypted backup"
    log "encrypting to ${BACKUP_AGE_RECIPIENT}"
    for f in "${DB_FILE}" "${FS_FILE}" "${CFG_FILE}"; do
        [[ -f "${f}" ]] || continue
        age -r "${BACKUP_AGE_RECIPIENT}" -o "${f}.age" "${f}" || die "encryption failed for ${f}"
        rm -f "${f}"
    done
else
    log "WARNING: BACKUP_AGE_RECIPIENT unset - backup is written UNENCRYPTED"
fi

# --- 5. Manifest with checksums --------------------------------------------
END_EPOCH="$(date -u +%s)"
DURATION=$(( END_EPOCH - START_EPOCH ))
ENCRYPTED=false
[[ -n "${BACKUP_AGE_RECIPIENT:-}" ]] && ENCRYPTED=true

log "computing checksums"
{
    printf '{\n'
    printf '  "timestamp": "%s",\n' "${TS}"
    printf '  "environment": "%s",\n' "${ENVIRONMENT}"
    printf '  "label": "%s",\n' "${LABEL}"
    printf '  "database": "%s",\n' "${POSTGRES_DB}"
    printf '  "image_tag": "%s",\n' "${ODOO_IMAGE_TAG:-unknown}"
    printf '  "encrypted": %s,\n' "${ENCRYPTED}"
    printf '  "duration_seconds": %s,\n' "${DURATION}"
    printf '  "database_size_bytes": %s,\n' "${db_size_bytes}"
    printf '  "files": [\n'
    first=1
    for f in "${SET_DIR}"/*; do
        [[ -f "${f}" ]] || continue
        [[ "${f}" == "${MANIFEST}" ]] && continue
        (( first )) || printf ',\n'
        first=0
        printf '    {"name": "%s", "bytes": %s, "sha256": "%s"}' \
            "$(basename "${f}")" \
            "$(stat -c %s "${f}")" \
            "$(sha256sum "${f}" | cut -d' ' -f1)"
    done
    printf '\n  ]\n}\n'
} > "${MANIFEST}"

# --- 6. Metrics for Prometheus ---------------------------------------------
# Written where node_exporter's textfile collector reads them, so a stale or
# failed backup becomes alertable like any other metric instead of being
# discovered during a restore.
TEXTFILE_DIR="${NODE_EXPORTER_TEXTFILE_DIR:-/var/lib/node_exporter/textfile_collector}"
if [[ -d "${TEXTFILE_DIR}" && -w "${TEXTFILE_DIR}" ]]; then
    total_bytes="$(du -sb "${SET_DIR}" | cut -f1)"
    tmp="${TEXTFILE_DIR}/odoo_backup.prom.$$"
    {
        echo '# HELP odoo_backup_last_success_timestamp_seconds Unix time of last successful backup.'
        echo '# TYPE odoo_backup_last_success_timestamp_seconds gauge'
        echo "odoo_backup_last_success_timestamp_seconds{environment=\"${ENVIRONMENT}\"} ${END_EPOCH}"
        echo '# HELP odoo_backup_duration_seconds Duration of the last successful backup.'
        echo '# TYPE odoo_backup_duration_seconds gauge'
        echo "odoo_backup_duration_seconds{environment=\"${ENVIRONMENT}\"} ${DURATION}"
        echo '# HELP odoo_backup_size_bytes Size of the last successful backup set.'
        echo '# TYPE odoo_backup_size_bytes gauge'
        echo "odoo_backup_size_bytes{environment=\"${ENVIRONMENT}\"} ${total_bytes}"
    } > "${tmp}"
    # Atomic rename so Prometheus never scrapes a half-written file.
    mv "${tmp}" "${TEXTFILE_DIR}/odoo_backup.prom"
    log "metrics written to ${TEXTFILE_DIR}/odoo_backup.prom"
else
    log "node_exporter textfile dir not writable - skipping metrics"
fi

# --- 7. Off-site copy ------------------------------------------------------
# 3-2-1: a copy on the OPS server is still inside the same infrastructure and
# does not survive a site-level event.
if [[ -n "${BACKUP_OFFSITE_TARGET:-}" ]]; then
    command -v rclone >/dev/null 2>&1 \
        || die "BACKUP_OFFSITE_TARGET is set but rclone is not installed"
    log "replicating off-site to ${BACKUP_OFFSITE_TARGET}"
    rclone copy "${SET_DIR}" "${BACKUP_OFFSITE_TARGET}/${ENVIRONMENT}/${TS}_${LABEL}" \
        || die "off-site replication FAILED - backup is NOT 3-2-1 compliant"
    log "off-site copy complete"
else
    log "WARNING: BACKUP_OFFSITE_TARGET unset - no off-site copy, 3-2-1 NOT satisfied"
fi

log "SUCCESS: ${SET_DIR} ($(du -sh "${SET_DIR}" | cut -f1), ${DURATION}s)"
echo "${SET_DIR}"
