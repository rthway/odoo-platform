#!/usr/bin/env bash
# ===========================================================================
# scripts/deploy.sh - deploy a specific, already-built image tag
# ===========================================================================
# This script NEVER builds. It pulls a tag that CI already built, scanned and
# promoted, which is what makes "the same artifact everywhere" true rather
# than aspirational.
#
# Flow:
#   record current tag -> pull new image -> (prod: backup) -> start ->
#   health check -> keep, or roll back automatically
#
# Deployment state lives in .deploy-state/ so rollback.sh knows what the
# previous known-good tag was. Without that record, "roll back" is guesswork.
#
# Usage: scripts/deploy.sh -e dev|qa|prod -t <image-tag> [--no-rollback]
# ===========================================================================
set -Eeuo pipefail

ENVIRONMENT=""
IMAGE_TAG=""
AUTO_ROLLBACK=1
COMPOSE_DIR="${COMPOSE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
STATE_DIR="${COMPOSE_DIR}/.deploy-state"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -e|--environment) ENVIRONMENT="$2"; shift 2 ;;
        -t|--tag)         IMAGE_TAG="$2"; shift 2 ;;
        --no-rollback)    AUTO_ROLLBACK=0; shift ;;
        -h|--help)        sed -n '2,18p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

log() { printf '%s [deploy] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die() { printf '%s [deploy] FATAL: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; exit 1; }

[[ -n "${ENVIRONMENT}" ]] || die "-e dev|qa|prod is required"
[[ -n "${IMAGE_TAG}" ]]   || die "-t <image-tag> is required"

case "${ENVIRONMENT}" in
    dev|qa|prod) ;;
    *) die "unknown environment '${ENVIRONMENT}'" ;;
esac

# 'latest' is mutable: two hosts pulling it can legitimately get different
# images, which destroys the promotion guarantee entirely.
[[ "${IMAGE_TAG}" != "latest" ]] \
    || die "refusing to deploy the mutable tag 'latest' - deploy an immutable tag or digest"

[[ -r "${COMPOSE_DIR}/.env" ]] || die "${COMPOSE_DIR}/.env is missing - Ansible renders it"

# Keep the requested environment: sourcing .env below will overwrite the
# ENVIRONMENT variable, and comparing it against itself would check nothing.
REQUESTED_ENV="${ENVIRONMENT}"

set -a
# shellcheck disable=SC1091
. "${COMPOSE_DIR}/.env"
set +a

HOST_ENV="${ENVIRONMENT:-}"

# A host whose .env says 'prod' while the caller passed -e qa means someone is
# about to deploy with the wrong overlay and the wrong database. Fail loudly
# rather than discovering it from the resulting incident.
if [[ "${REQUESTED_ENV}" != "${HOST_ENV}" ]]; then
    die "requested environment '${REQUESTED_ENV}' but this host's .env says '${HOST_ENV}' - refusing"
fi

ENVIRONMENT="${REQUESTED_ENV}"

compose() {
    ODOO_IMAGE_TAG="${IMAGE_TAG}" docker compose \
        --project-directory "${COMPOSE_DIR}" \
        -f "${COMPOSE_DIR}/compose.yml" \
        -f "${COMPOSE_DIR}/compose.${ENVIRONMENT}.yml" "$@"
}

mkdir -p "${STATE_DIR}"
CURRENT_FILE="${STATE_DIR}/current"
PREVIOUS_FILE="${STATE_DIR}/previous"
HISTORY_FILE="${STATE_DIR}/history.log"

PREVIOUS_TAG="$(cat "${CURRENT_FILE}" 2>/dev/null || echo '')"

log "environment      : ${ENVIRONMENT}"
log "image            : ${ODOO_IMAGE}"
log "deploying tag    : ${IMAGE_TAG}"
log "currently running: ${PREVIOUS_TAG:-<none, first deployment>}"

if [[ "${PREVIOUS_TAG}" == "${IMAGE_TAG}" ]]; then
    log "requested tag is already deployed; continuing anyway to converge state"
fi

# ---------------------------------------------------------------------------
# 1. Pull FIRST, before stopping anything
# ---------------------------------------------------------------------------
# If the registry is unreachable or the tag does not exist, we find out now,
# while the old version is still happily serving traffic.
log "pulling ${ODOO_IMAGE}:${IMAGE_TAG}"
docker pull "${ODOO_IMAGE}:${IMAGE_TAG}" \
    || die "could not pull the image - nothing was changed, the current deployment is untouched"

# Record the digest. The tag says what we asked for; the digest says what we
# actually got, and that is what belongs in an audit trail.
DIGEST="$(docker inspect --format '{{index .RepoDigests 0}}' "${ODOO_IMAGE}:${IMAGE_TAG}" 2>/dev/null || echo 'unknown')"
log "resolved digest  : ${DIGEST}"

# ---------------------------------------------------------------------------
# 2. Production: back up before changing anything
# ---------------------------------------------------------------------------
BACKUP_SET=""
if [[ "${ENVIRONMENT}" == "prod" ]]; then
    log "taking a pre-deployment backup"
    BACKUP_SET="$("${COMPOSE_DIR}/scripts/backup.sh" -e prod -l pre-deploy | tail -1)" \
        || die "pre-deployment backup FAILED - refusing to deploy to production without one"
    log "backup: ${BACKUP_SET}"

    log "verifying that backup is intact"
    "${COMPOSE_DIR}/scripts/verify-backup.sh" -s "${BACKUP_SET}" --checksums \
        || die "pre-deployment backup failed verification - refusing to deploy"
fi

# ---------------------------------------------------------------------------
# 3. Deploy
# ---------------------------------------------------------------------------
log "starting the stack on ${IMAGE_TAG}"
if ! compose up -d --remove-orphans; then
    log "compose up FAILED"
    if (( AUTO_ROLLBACK == 1 )) && [[ -n "${PREVIOUS_TAG}" ]]; then
        log "rolling back to ${PREVIOUS_TAG}"
        "${COMPOSE_DIR}/scripts/rollback.sh" -e "${ENVIRONMENT}" --reason "compose up failed"
    fi
    die "deployment failed at container start"
fi

# ---------------------------------------------------------------------------
# 4. Health check - the gate that decides keep vs roll back
# ---------------------------------------------------------------------------
log "running health checks"
if "${COMPOSE_DIR}/scripts/healthcheck.sh" -e "${ENVIRONMENT}" -t "${HEALTHCHECK_TIMEOUT:-180}"; then
    HEALTHY=1
else
    HEALTHY=0
fi

if (( HEALTHY == 0 )); then
    log "HEALTH CHECKS FAILED for ${IMAGE_TAG}"
    if (( AUTO_ROLLBACK == 1 )) && [[ -n "${PREVIOUS_TAG}" ]]; then
        log "automatic rollback to ${PREVIOUS_TAG}"
        "${COMPOSE_DIR}/scripts/rollback.sh" -e "${ENVIRONMENT}" \
            --reason "health check failed for ${IMAGE_TAG}"
        die "deployment of ${IMAGE_TAG} failed health checks and was rolled back"
    fi
    die "deployment of ${IMAGE_TAG} failed health checks and NO rollback was performed"
fi

# ---------------------------------------------------------------------------
# 5. Commit the new state
# ---------------------------------------------------------------------------
# Only written after health checks pass, so `previous` always names a tag that
# was genuinely healthy at some point - which is the whole point of rollback.
if [[ -n "${PREVIOUS_TAG}" && "${PREVIOUS_TAG}" != "${IMAGE_TAG}" ]]; then
    echo "${PREVIOUS_TAG}" > "${PREVIOUS_FILE}"
fi
echo "${IMAGE_TAG}" > "${CURRENT_FILE}"

printf '%s deploy env=%s tag=%s digest=%s previous=%s backup=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${ENVIRONMENT}" "${IMAGE_TAG}" \
    "${DIGEST}" "${PREVIOUS_TAG:-none}" "${BACKUP_SET:-none}" >> "${HISTORY_FILE}"

# Free disk from superseded images, keeping the previous one so rollback does
# not need to re-pull during an incident.
log "pruning dangling images"
docker image prune -f >/dev/null 2>&1 || true

log "SUCCESS: ${ENVIRONMENT} is running ${IMAGE_TAG} and is healthy"
log "rollback target if needed: ${PREVIOUS_TAG:-<none>}"
