#!/usr/bin/env bash
# ===========================================================================
# scripts/rollback.sh - return the application to the previous known-good tag
# ===========================================================================
# SCOPE: this rolls back the APPLICATION ONLY.
#
# It deliberately does NOT touch the database. Application rollback and
# database rollback are different problems with different risk profiles:
#
#   - Reverting a container image is cheap, fast and reversible.
#   - Reverting a database that has already run an Odoo schema migration is
#     NOT. Odoo migrations are one-way: they rewrite tables, drop columns and
#     transform data. Restoring a pre-migration dump discards every
#     transaction committed since it was taken.
#
# So if the new version migrated the schema, rolling the image back may leave
# old code facing a new schema. That case is an incident, not a rollback:
# follow docs/disaster-recovery.md, which requires an explicit decision about
# accepting data loss.
#
# Usage: scripts/rollback.sh -e dev|qa|prod [-t <tag>] [--reason "..."]
# ===========================================================================
set -Eeuo pipefail

ENVIRONMENT=""
TARGET_TAG=""
REASON="manual rollback"
COMPOSE_DIR="${COMPOSE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
STATE_DIR="${COMPOSE_DIR}/.deploy-state"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -e|--environment) ENVIRONMENT="$2"; shift 2 ;;
        -t|--tag)         TARGET_TAG="$2"; shift 2 ;;
        --reason)         REASON="$2"; shift 2 ;;
        -h|--help)        sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

log() { printf '%s [rollback] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die() { printf '%s [rollback] FATAL: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; exit 1; }

[[ -n "${ENVIRONMENT}" ]] || die "-e dev|qa|prod is required"

[[ -r "${COMPOSE_DIR}/.env" ]] || die "${COMPOSE_DIR}/.env is missing"
set -a
# shellcheck disable=SC1091
. "${COMPOSE_DIR}/.env"
set +a

CURRENT_FILE="${STATE_DIR}/current"
PREVIOUS_FILE="${STATE_DIR}/previous"
HISTORY_FILE="${STATE_DIR}/history.log"

CURRENT_TAG="$(cat "${CURRENT_FILE}" 2>/dev/null || echo '')"

if [[ -z "${TARGET_TAG}" ]]; then
    TARGET_TAG="$(cat "${PREVIOUS_FILE}" 2>/dev/null || echo '')"
    [[ -n "${TARGET_TAG}" ]] || die \
        "no previous tag recorded in ${PREVIOUS_FILE}. Pass -t <tag> explicitly. Deployment history: ${HISTORY_FILE}"
fi

if [[ "${TARGET_TAG}" == "${CURRENT_TAG}" ]]; then
    die "target tag ${TARGET_TAG} is already the running tag - nothing to roll back to"
fi

log "environment : ${ENVIRONMENT}"
log "current tag : ${CURRENT_TAG:-<unknown>}"
log "rolling to  : ${TARGET_TAG}"
log "reason      : ${REASON}"

compose() {
    ODOO_IMAGE_TAG="${TARGET_TAG}" docker compose \
        --project-directory "${COMPOSE_DIR}" \
        -f "${COMPOSE_DIR}/compose.yml" \
        -f "${COMPOSE_DIR}/compose.${ENVIRONMENT}.yml" "$@"
}

# ---------------------------------------------------------------------------
# 1. Make sure the target image is actually available
# ---------------------------------------------------------------------------
# Normally still in the local cache from the previous deployment. During an
# incident the registry may also be unreachable, so check local first.
if docker image inspect "${ODOO_IMAGE}:${TARGET_TAG}" >/dev/null 2>&1; then
    log "target image is present locally"
else
    log "target image not cached, pulling"
    docker pull "${ODOO_IMAGE}:${TARGET_TAG}" \
        || die "cannot obtain ${ODOO_IMAGE}:${TARGET_TAG} - rollback impossible, escalate per docs/incident-response.md"
fi

# ---------------------------------------------------------------------------
# 2. Warn about schema migrations
# ---------------------------------------------------------------------------
# We cannot reliably detect whether the failed release migrated the schema, so
# say so plainly rather than implying a guarantee the script cannot give.
if [[ "${ENVIRONMENT}" == "prod" ]]; then
    cat <<'WARN'

  ------------------------------------------------------------------
  NOTE: this reverts the APPLICATION IMAGE ONLY.

  If the release being rolled back applied an Odoo schema migration,
  the database is still migrated. Older code against a newer schema
  can fail in subtle ways.

  After this completes, verify with the checks in
  docs/rollback.md, and if the schema was migrated, treat this as an
  incident: docs/disaster-recovery.md.
  ------------------------------------------------------------------

WARN
fi

# ---------------------------------------------------------------------------
# 3. Roll back
# ---------------------------------------------------------------------------
log "starting ${TARGET_TAG}"
compose up -d --remove-orphans || die "rollback failed to start containers - ESCALATE IMMEDIATELY"

# ---------------------------------------------------------------------------
# 4. Verify the rollback actually restored service
# ---------------------------------------------------------------------------
log "running health checks against the rolled-back version"
if "${COMPOSE_DIR}/scripts/healthcheck.sh" -e "${ENVIRONMENT}" -t "${HEALTHCHECK_TIMEOUT:-180}"; then
    log "health checks PASSED on ${TARGET_TAG}"
else
    # Do not roll back the rollback: a loop between two broken versions turns
    # a bad deploy into a prolonged outage. Stop and hand over to a human.
    cat <<'ESCALATE' >&2

  ##################################################################
  #  ROLLBACK COMPLETED BUT THE SERVICE IS STILL UNHEALTHY         #
  #                                                                #
  #  Do NOT keep cycling versions. The fault is probably not the   #
  #  application image: check PostgreSQL, disk, and whether a      #
  #  schema migration has left the database ahead of the code.     #
  #                                                                #
  #  Follow docs/incident-response.md now.                         #
  ##################################################################

ESCALATE
    die "rollback did not restore health - escalated"
fi

# ---------------------------------------------------------------------------
# 5. Record it
# ---------------------------------------------------------------------------
mkdir -p "${STATE_DIR}"
echo "${TARGET_TAG}" > "${CURRENT_FILE}"
# The failed tag becomes the "previous" entry, so a fix-forward deployment
# still has an accurate record of what was running.
[[ -n "${CURRENT_TAG}" ]] && echo "${CURRENT_TAG}" > "${PREVIOUS_FILE}"

printf '%s ROLLBACK env=%s from=%s to=%s reason=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${ENVIRONMENT}" \
    "${CURRENT_TAG:-unknown}" "${TARGET_TAG}" "${REASON}" >> "${HISTORY_FILE}"

log "SUCCESS: ${ENVIRONMENT} rolled back to ${TARGET_TAG} and is healthy"
