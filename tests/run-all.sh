#!/usr/bin/env bash
# ===========================================================================
# tests/run-all.sh - run the suites that need no running stack
# ===========================================================================
# Safe to run anywhere, including a laptop with no Docker daemon: lint,
# configuration and security assertions only.
#
# The runtime suites (smoke, integration, Odoo modules) need a deployed
# environment and are invoked by the deployment workflows instead.
#
# Usage: tests/run-all.sh [--with-runtime -e dev|qa]
# ===========================================================================
set -Eeuo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_DIR}"

WITH_RUNTIME=0
ENVIRONMENT="dev"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --with-runtime) WITH_RUNTIME=1; shift ;;
        -e|--environment) ENVIRONMENT="$2"; shift 2 ;;
        -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

SUITES=(test-lint.sh test-config.sh test-security.sh)
if (( WITH_RUNTIME == 1 )); then
    SUITES+=(test-smoke.sh test-integration.sh)
fi

FAILED_SUITES=()
START="$(date +%s)"

for suite in "${SUITES[@]}"; do
    printf '\n==================================================================\n'
    printf '  %s\n' "${suite}"
    printf '==================================================================\n'

    args=()
    case "${suite}" in
        test-smoke.sh|test-integration.sh) args=(-e "${ENVIRONMENT}") ;;
    esac

    # `|| true` is deliberate: every suite runs even when an earlier one
    # fails, so one report shows every problem instead of only the first.
    if "./tests/${suite}" "${args[@]}"; then
        :
    else
        FAILED_SUITES+=("${suite}")
    fi
done

DURATION=$(( $(date +%s) - START ))

printf '\n==================================================================\n'
printf '  SUMMARY (%ss)\n' "${DURATION}"
printf '==================================================================\n'

for suite in "${SUITES[@]}"; do
    status="PASS"
    for f in ${FAILED_SUITES[@]+"${FAILED_SUITES[@]}"}; do
        [[ "${f}" == "${suite}" ]] && status="FAIL"
    done
    printf '  %-4s  %s\n' "${status}" "${suite}"
done

echo
if (( ${#FAILED_SUITES[@]} == 0 )); then
    echo "  ALL SUITES PASSED"
    exit 0
fi
printf '  %s suite(s) FAILED: %s\n' "${#FAILED_SUITES[@]}" "${FAILED_SUITES[*]}"
exit 1
