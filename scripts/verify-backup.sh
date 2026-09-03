#!/usr/bin/env bash
# ===========================================================================
# scripts/verify-backup.sh - prove a backup is actually restorable
# ===========================================================================
# A backup is not a backup until it has been restored. This script offers two
# levels, and only the second one is real evidence:
#
#   --checksums  (fast, safe, run after every backup)
#       Recompute SHA-256 for every file and compare against the manifest.
#       Proves the bytes on disk are intact. Proves NOTHING about whether
#       PostgreSQL can read them.
#
#   --restore    (slow, run on a schedule - this is the one that counts)
#       Spin up a THROWAWAY PostgreSQL container, restore the dump into it,
#       and query real Odoo tables. Touches no existing database, no existing
#       volume and no running stack.
#
# Usage: scripts/verify-backup.sh -s <backup-set-dir> [--checksums|--restore]
# ===========================================================================
set -Eeuo pipefail

SET_DIR=""
MODE="checksums"
PG_VERSION="${POSTGRES_VERSION:-16.15-alpine3.24}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -s|--set)     SET_DIR="$2"; shift 2 ;;
        --checksums)  MODE="checksums"; shift ;;
        --restore)    MODE="restore"; shift ;;
        -h|--help)    sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

log()  { printf '%s [verify] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die()  { printf '%s [verify] FAIL: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; exit 1; }

[[ -n "${SET_DIR}" ]]      || die "-s <backup-set-dir> is required"
[[ -d "${SET_DIR}" ]]      || die "no such backup set: ${SET_DIR}"
MANIFEST="${SET_DIR}/manifest.json"
[[ -r "${MANIFEST}" ]]     || die "manifest.json missing from ${SET_DIR}"

# ---------------------------------------------------------------------------
# Level 1: checksum integrity
# ---------------------------------------------------------------------------
log "verifying checksums against manifest"
python3 - "${SET_DIR}" <<'PY' || die "checksum verification FAILED"
import hashlib, json, pathlib, sys

set_dir = pathlib.Path(sys.argv[1])
manifest = json.loads((set_dir / "manifest.json").read_text())

failures = 0
for entry in manifest["files"]:
    path = set_dir / entry["name"]
    if not path.is_file():
        print(f"  MISSING  {entry['name']}")
        failures += 1
        continue

    size = path.stat().st_size
    if size != entry["bytes"]:
        print(f"  SIZE     {entry['name']}: {size} on disk, {entry['bytes']} in manifest")
        failures += 1
        continue

    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            h.update(chunk)

    if h.hexdigest() != entry["sha256"]:
        print(f"  CORRUPT  {entry['name']}: checksum mismatch")
        failures += 1
    else:
        print(f"  OK       {entry['name']} ({size} bytes)")

if failures:
    print(f"{failures} file(s) failed verification")
    sys.exit(1)
print(f"all {len(manifest['files'])} file(s) intact")
PY

log "checksum verification PASSED"

if [[ "${MODE}" == "checksums" ]]; then
    log "NOTE: checksums only. This does NOT prove the dump is restorable."
    log "      Run with --restore on a schedule for real evidence."
    exit 0
fi

# ---------------------------------------------------------------------------
# Level 2: real restore into a throwaway container
# ---------------------------------------------------------------------------
DUMP="${SET_DIR}/database.dump"
if [[ ! -f "${DUMP}" ]]; then
    if [[ -f "${DUMP}.age" ]]; then
        command -v age >/dev/null 2>&1 || die "backup is encrypted but 'age' is not installed"
        [[ -n "${BACKUP_AGE_IDENTITY:-}" ]] \
            || die "backup is encrypted; set BACKUP_AGE_IDENTITY to the private key file"
        TMP_PLAIN="$(mktemp -d)"
        trap 'rm -rf "${TMP_PLAIN}"' EXIT
        log "decrypting dump"
        age -d -i "${BACKUP_AGE_IDENTITY}" -o "${TMP_PLAIN}/database.dump" "${DUMP}.age" \
            || die "decryption failed"
        DUMP="${TMP_PLAIN}/database.dump"
    else
        die "no database.dump or database.dump.age in ${SET_DIR}"
    fi
fi

# A unique name and an anonymous volume: nothing here can collide with, or
# outlive, the running stack. The container is removed unconditionally.
CTR="odoo-verify-$$-$(date +%s)"
VERIFY_PW="verify-$(head -c 16 /dev/urandom | base64 | tr -dc 'A-Za-z0-9')"

cleanup_ctr() {
    log "removing throwaway container ${CTR}"
    docker rm -f "${CTR}" >/dev/null 2>&1 || true
}
trap 'cleanup_ctr' EXIT

log "starting throwaway PostgreSQL ${PG_VERSION} as ${CTR}"
docker run -d --rm \
    --name "${CTR}" \
    -e POSTGRES_PASSWORD="${VERIFY_PW}" \
    -e POSTGRES_USER=verify \
    -e POSTGRES_DB=verify \
    "postgres:${PG_VERSION}" >/dev/null || die "could not start verification container"

log "waiting for it to accept connections"
deadline=$(( SECONDS + 90 ))
until docker exec "${CTR}" pg_isready -U verify -d verify -q 2>/dev/null; do
    (( SECONDS < deadline )) || die "verification database never became ready"
    sleep 2
done

log "restoring dump (this is the step that actually proves the backup works)"
RESTORE_START="$(date -u +%s)"
if ! docker exec -i "${CTR}" pg_restore \
        -U verify -d verify --no-owner --no-acl --exit-on-error \
        < "${DUMP}" 2>/tmp/verify-restore.$$.log; then
    log "pg_restore output:"
    sed 's/^/    /' "/tmp/verify-restore.$$.log" >&2 || true
    rm -f "/tmp/verify-restore.$$.log"
    die "RESTORE FAILED - this backup is NOT usable"
fi
rm -f "/tmp/verify-restore.$$.log"
RESTORE_SECONDS=$(( $(date -u +%s) - RESTORE_START ))
log "restore completed in ${RESTORE_SECONDS}s"

# --- Sanity-check the restored data ----------------------------------------
# A restore that "succeeds" into an empty database is not a restore. Confirm
# core Odoo tables exist and hold rows.
log "checking restored contents"
q() { docker exec "${CTR}" psql -U verify -d verify -tAc "$1" 2>/dev/null | tr -d '[:space:]'; }

tables="$(q "SELECT count(*) FROM information_schema.tables WHERE table_schema='public'")"
[[ "${tables}" =~ ^[0-9]+$ && "${tables}" -gt 50 ]] \
    || die "only ${tables} public tables restored - an Odoo database has hundreds"
log "  public tables: ${tables}"

for t in res_users res_company ir_module_module; do
    if [[ "$(q "SELECT to_regclass('public.${t}') IS NOT NULL")" != "t" ]]; then
        die "core Odoo table '${t}' is missing from the restore"
    fi
    log "  ${t}: $(q "SELECT count(*) FROM ${t}") rows"
done

installed="$(q "SELECT count(*) FROM ir_module_module WHERE state='installed'")"
[[ "${installed}" =~ ^[0-9]+$ && "${installed}" -gt 0 ]] \
    || die "no installed modules found - the restore is not a working Odoo database"
log "  installed modules: ${installed}"

# --- Record the result -------------------------------------------------------
RESULT_FILE="${SET_DIR}/verification.json"
cat > "${RESULT_FILE}" <<EOF
{
  "verified_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "mode": "restore",
  "result": "PASS",
  "restore_duration_seconds": ${RESTORE_SECONDS},
  "public_tables": ${tables},
  "installed_modules": ${installed}
}
EOF

TEXTFILE_DIR="${NODE_EXPORTER_TEXTFILE_DIR:-/var/lib/node_exporter/textfile_collector}"
if [[ -d "${TEXTFILE_DIR}" && -w "${TEXTFILE_DIR}" ]]; then
    tmp="${TEXTFILE_DIR}/odoo_backup_verify.prom.$$"
    {
        echo '# HELP odoo_backup_verify_last_success_timestamp_seconds Unix time of the last PASSING restore test.'
        echo '# TYPE odoo_backup_verify_last_success_timestamp_seconds gauge'
        echo "odoo_backup_verify_last_success_timestamp_seconds $(date -u +%s)"
        echo '# HELP odoo_backup_restore_duration_seconds How long the verification restore took (informs RTO).'
        echo '# TYPE odoo_backup_restore_duration_seconds gauge'
        echo "odoo_backup_restore_duration_seconds ${RESTORE_SECONDS}"
    } > "${tmp}"
    mv "${tmp}" "${TEXTFILE_DIR}/odoo_backup_verify.prom"
fi

log "PASS - backup restored and verified. Result written to ${RESULT_FILE}"
log "Measured restore time for this dataset: ${RESTORE_SECONDS}s (feeds the RTO in docs/disaster-recovery.md)"
