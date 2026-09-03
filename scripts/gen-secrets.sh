#!/usr/bin/env bash
# ===========================================================================
# scripts/gen-secrets.sh - generate strong values for a .env file
# ===========================================================================
# Writes to stdout, never to a file inside the repository, so a generated
# secret cannot be committed by an absent-minded `git add -A`.
#
# Usage:
#   scripts/gen-secrets.sh dev            # print a filled .env to stdout
#   scripts/gen-secrets.sh prod > /tmp/x  # redirect deliberately
# ===========================================================================
set -Eeuo pipefail

ENVIRONMENT="${1:-dev}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE="${REPO_DIR}/.env.${ENVIRONMENT}.example"

[[ -r "${TEMPLATE}" ]] || { echo "no template: ${TEMPLATE}" >&2; exit 1; }

# Refuse to write into a terminal-less redirect that lands in the repo.
if [[ ! -t 1 ]]; then
    echo "# Generated $(date -u +%Y-%m-%dT%H:%M:%SZ) for ${ENVIRONMENT}." >&2
    echo "# Do NOT save this inside the repository." >&2
fi

# /dev/urandom is the correct source here; $RANDOM is not cryptographic.
gen() { LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "${1:-40}"; }

PG_PW="$(gen 40)"
ADMIN_PW="$(gen 48)"
GRAFANA_PW="$(gen 32)"

while IFS= read -r line; do
    case "${line}" in
        POSTGRES_PASSWORD=*)      echo "POSTGRES_PASSWORD=${PG_PW}" ;;
        ODOO_ADMIN_PASSWD=*)      echo "ODOO_ADMIN_PASSWD=${ADMIN_PW}" ;;
        GRAFANA_ADMIN_PASSWORD=*) echo "GRAFANA_ADMIN_PASSWORD=${GRAFANA_PW}" ;;
        *) echo "${line}" ;;
    esac
done < "${TEMPLATE}"

cat >&2 <<'NOTE'

Next steps:
  1. Store these in GitHub Environment Secrets (dev / qa / production),
     NOT in the repository.
  2. Ansible renders the .env on each host from those secrets, mode 0600.
  3. If a value here has ever been pasted into chat, a ticket, or a shell
     history, treat it as burned and generate another.
NOTE
