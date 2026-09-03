#!/usr/bin/env bash
# ===========================================================================
# scripts/prune-backups.sh - apply the retention policy
# ===========================================================================
# Grandfather-father-son: keep N daily, N weekly (Mondays), N monthly (1st).
#
# Two deliberate safety properties:
#   1. It NEVER deletes the most recent backup, whatever the policy says. A
#      retention bug must not be able to leave an environment with none.
#   2. --dry-run is the default. Deletion requires --apply.
#
# Usage: scripts/prune-backups.sh -e prod [--apply]
# ===========================================================================
set -Eeuo pipefail

ENVIRONMENT="prod"
APPLY=0
COMPOSE_DIR="${COMPOSE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
BACKUP_DIR_OPT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -e|--environment) ENVIRONMENT="$2"; shift 2 ;;
        -d|--dir)         BACKUP_DIR_OPT="$2"; shift 2 ;;
        --apply)          APPLY=1; shift ;;
        --dry-run)        APPLY=0; shift ;;
        -h|--help)        sed -n '2,14p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

# Resolve a working Python 3. It is `python3` on Linux hosts and often just
# `python` elsewhere - and on Windows `command -v python3` finds the Microsoft
# Store alias stub, which exists but is not an interpreter. So each candidate
# is executed, not merely located.
PYTHON=""
for _candidate in python3 python; do
    if "${_candidate}" -c 'import sys; sys.exit(0 if sys.version_info[0] == 3 else 1)' >/dev/null 2>&1; then
        PYTHON="${_candidate}"
        break
    fi
done
[[ -n "${PYTHON}" ]] || { echo "a working python3 is required but none was found" >&2; exit 1; }

log() { printf '%s [prune] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

if [[ -r "${COMPOSE_DIR}/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    . "${COMPOSE_DIR}/.env"
    set +a
fi

BACKUP_DIR="${BACKUP_DIR_OPT:-${BACKUP_DIR:-/var/backups/odoo}}"
ROOT="${BACKUP_DIR}/${ENVIRONMENT}"
[[ -d "${ROOT}" ]] || { log "nothing to prune: ${ROOT} does not exist"; exit 0; }

KEEP_DAILY="${BACKUP_RETENTION_DAILY:-7}"
KEEP_WEEKLY="${BACKUP_RETENTION_WEEKLY:-4}"
KEEP_MONTHLY="${BACKUP_RETENTION_MONTHLY:-6}"

log "policy: ${KEEP_DAILY} daily, ${KEEP_WEEKLY} weekly, ${KEEP_MONTHLY} monthly"
(( APPLY == 1 )) && log "MODE: APPLY (backups will be deleted)" \
                 || log "MODE: DRY RUN (nothing will be deleted; pass --apply)"

"${PYTHON}" - "${ROOT}" "${KEEP_DAILY}" "${KEEP_WEEKLY}" "${KEEP_MONTHLY}" "${APPLY}" <<'PY'
import datetime as dt
import pathlib
import shutil
import sys

root = pathlib.Path(sys.argv[1])
keep_daily, keep_weekly, keep_monthly = (int(x) for x in sys.argv[2:5])
apply_changes = sys.argv[5] == "1"

# Directory names are <UTC timestamp>_<label>, e.g. 20260903T010000Z_daily.
sets = []
for path in sorted(root.iterdir()):
    if not path.is_dir():
        continue
    stamp = path.name.split("_", 1)[0]
    try:
        when = dt.datetime.strptime(stamp, "%Y%m%dT%H%M%SZ")
    except ValueError:
        print(f"  SKIP    {path.name} (unrecognised name, left alone)")
        continue
    sets.append((when, path))

if not sets:
    print("  no backup sets found")
    sys.exit(0)

sets.sort(key=lambda item: item[0], reverse=True)

keep: set[pathlib.Path] = set()
reason: dict[pathlib.Path, str] = {}

def mark(path, why):
    if path not in keep:
        keep.add(path)
        reason[path] = why

# Rule 1, absolute: the newest set is always kept.
mark(sets[0][1], "newest (always retained)")

for when, path in sets[:keep_daily]:
    mark(path, "daily")

weekly = [(w, p) for w, p in sets if w.weekday() == 0]
for when, path in weekly[:keep_weekly]:
    mark(path, "weekly (Monday)")

monthly = [(w, p) for w, p in sets if w.day == 1]
for when, path in monthly[:keep_monthly]:
    mark(path, "monthly (1st)")

# A verified restore test is expensive evidence; do not discard it casually.
for when, path in sets:
    if (path / "verification.json").exists():
        mark(path, "has a passing restore verification")

kept = deleted = 0
freed = 0

for when, path in sets:
    if path in keep:
        print(f"  KEEP    {path.name}  ({reason[path]})")
        kept += 1
        continue

    size = sum(f.stat().st_size for f in path.rglob("*") if f.is_file())
    freed += size
    if apply_changes:
        shutil.rmtree(path)
        print(f"  DELETED {path.name}  ({size / 1048576:.1f} MB)")
    else:
        print(f"  WOULD DELETE {path.name}  ({size / 1048576:.1f} MB)")
    deleted += 1

verb = "deleted" if apply_changes else "would delete"
print(f"\n  {kept} kept, {deleted} {verb}, {freed / 1048576:.1f} MB {'freed' if apply_changes else 'reclaimable'}")

if kept == 0:
    print("  ERROR: retention would leave zero backups", file=sys.stderr)
    sys.exit(1)
PY

log "done"
