#!/usr/bin/env bash
# ===========================================================================
# scripts/gen-local-tls.sh - self-signed certificate for local and CI use
# ===========================================================================
# nginx terminates TLS, so it will NOT START without a certificate. That is
# correct behaviour for production, but it means a fresh clone cannot bring
# the stack up until one exists. This generates a throwaway pair.
#
# NEVER for production. Production certificates come from Let's Encrypt, and
# the odoo_deploy Ansible role deliberately refuses to configure a prod host
# that has no real certificate.
#
# Usage: scripts/gen-local-tls.sh [-d localhost] [-o config/nginx/tls]
# ===========================================================================
set -Eeuo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOMAIN="localhost"
OUT_DIR="${REPO_DIR}/config/nginx/tls"
DAYS=365
FORCE=0

while getopts ":d:o:fh" opt; do
    case "${opt}" in
        d) DOMAIN="${OPTARG}" ;;
        o) OUT_DIR="${OPTARG}" ;;
        f) FORCE=1 ;;
        h) sed -n '2,14p' "$0"; exit 0 ;;
        *) echo "unknown option -${OPTARG}" >&2; exit 2 ;;
    esac
done

log() { printf '%s [gen-tls] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die() { printf '%s [gen-tls] FATAL: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; exit 1; }

command -v openssl >/dev/null 2>&1 || die "openssl is required"

# Refuse to overwrite an existing certificate unless asked. On a host that
# already has a real certificate, silently replacing it with a self-signed
# one would take the site down with browser warnings.
CERT="${OUT_DIR}/fullchain.pem"
KEY="${OUT_DIR}/privkey.pem"

if [[ -f "${CERT}" && "${FORCE}" -eq 0 ]]; then
    log "certificate already exists at ${CERT}"
    # Run from OUT_DIR with a bare filename, for the same path reason as below.
    if ( cd "${OUT_DIR}" && openssl x509 -in fullchain.pem -noout -checkend 0 ) >/dev/null 2>&1; then
        log "it is still valid; nothing to do (pass -f to replace it)"
        ( cd "${OUT_DIR}" && openssl x509 -in fullchain.pem -noout -subject -dates ) | sed 's/^/    /'
        exit 0
    fi
    die "the existing certificate has EXPIRED. Renew it properly, or pass -f to replace it with a self-signed one"
fi

# A guard, not a formality: ENVIRONMENT=prod means this is a production host.
if [[ "${ENVIRONMENT:-}" == "prod" && "${ALLOW_SELF_SIGNED_PROD:-}" != "yes" ]]; then
    die "refusing to generate a self-signed certificate for ENVIRONMENT=prod - see docs/security.md"
fi

mkdir -p "${OUT_DIR}"

log "generating a self-signed certificate for ${DOMAIN} (${DAYS} days)"

# The subject and extensions go in a config file rather than on the command
# line. `-subj "/C=NP/..."` is mangled by Git Bash into a Windows path before
# openssl ever sees it; a config file cannot be mangled.
#
# subjectAltName is not optional: modern browsers and curl ignore the legacy
# Common Name entirely, so a certificate without SAN is rejected outright.
# Written next to the output rather than in $TMPDIR: a Git Bash mktemp path
# ("/tmp/tmp.XXXX") is not a path a native Windows openssl can open, and the
# failure is an unhelpful "No such file or directory".
CONF="${OUT_DIR}/.openssl-selfsigned.cnf"
trap 'rm -f "${CONF}" "${CONF}.err"' EXIT

cat > "${CONF}" <<CONFEOF
[req]
distinguished_name = dn
x509_extensions    = v3
prompt             = no

[dn]
C  = NP
O  = Odoo Platform (self-signed)
CN = ${DOMAIN}

[v3]
subjectAltName         = DNS:${DOMAIN}, DNS:localhost, IP:127.0.0.1
basicConstraints       = critical, CA:FALSE
keyUsage               = critical, digitalSignature, keyEncipherment
extendedKeyUsage       = serverAuth
CONFEOF

# Run from inside the output directory with bare filenames. Absolute paths
# here are POSIX ("/c/Users/...") under Git Bash, which a native Windows
# openssl cannot open; relative names are understood by both.
if ! ( cd "${OUT_DIR}" && openssl req -x509 -nodes \
        -newkey rsa:2048 \
        -days "${DAYS}" \
        -keyout "privkey.pem" \
        -out "fullchain.pem" \
        -config ".openssl-selfsigned.cnf" \
        2>".openssl-selfsigned.cnf.err" ); then
    sed 's/^/    /' "${CONF}.err" >&2 2>/dev/null || true
    die "openssl failed to generate the certificate"
fi

chmod 600 "${KEY}"
chmod 644 "${CERT}"

log "written:"
log "  ${CERT}"
log "  ${KEY}"
( cd "${OUT_DIR}" && openssl x509 -in fullchain.pem -noout -subject -dates -ext subjectAltName ) \
    | sed 's/^/    /'

cat <<'NOTE'

  This certificate is SELF-SIGNED. Browsers will warn, and curl needs -k.
  That is expected for local and CI use.

  Production uses Let's Encrypt - see docs/runbook.md#renew-ssl. The
  odoo_deploy Ansible role refuses to configure a production host that has
  no real certificate.
NOTE
