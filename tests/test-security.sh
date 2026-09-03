#!/usr/bin/env bash
# ===========================================================================
# tests/test-security.sh - static security assertions
# ===========================================================================
# Runs without Docker and without a running stack, so it is cheap enough to
# gate every pull request. It asserts the properties that are easy to break
# by accident and expensive to discover later.
# ===========================================================================
set -Eeuo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_DIR}"

PASS=0
FAIL=0
pass() { printf '  PASS  %s\n' "$*"; PASS=$(( PASS + 1 )); }
fail() { printf '  FAIL  %s\n' "$*"; FAIL=$(( FAIL + 1 )); }

echo "== Security assertions =="

# ---------------------------------------------------------------------------
# 1. Example env files must contain placeholders, never values
# ---------------------------------------------------------------------------
# The whole secret-handling design rests on this. If a real password is ever
# committed to an .example file, gitleaks' allowlist would let it through.
SENSITIVE='POSTGRES_PASSWORD|ODOO_ADMIN_PASSWD|GRAFANA_ADMIN_PASSWORD|BACKUP_AGE_IDENTITY|DOCKERHUB_TOKEN|SSH_PRIVATE_KEY'

for f in .env.example .env.dev.example .env.qa.example .env.prod.example; do
    [[ -f "${f}" ]] || { fail "${f} is missing"; continue; }
    if bad="$(grep -nE "^(${SENSITIVE})=.+" "${f}" || true)"; then
        if [[ -n "${bad}" ]]; then
            fail "${f} assigns a value to a sensitive key:"
            echo "${bad}" | sed 's/^/          /'
            continue
        fi
    fi
    pass "${f} keeps sensitive keys empty"
done

# ---------------------------------------------------------------------------
# 2. No real .env file may be tracked
# ---------------------------------------------------------------------------
# Any .env variant EXCEPT the *.example templates, which are meant to be
# tracked. Without the second filter, '.env.example' matches '^\.env\.[a-z]+$'.
if tracked="$(git ls-files | grep -E '^\.env($|\.)' | grep -v '\.example$' || true)"; then
    if [[ -n "${tracked}" ]]; then
        fail "a real .env file is tracked by git: ${tracked}"
    else
        pass "no real .env file is tracked"
    fi
fi

# ---------------------------------------------------------------------------
# 3. No private keys or certificates anywhere in the tree
# ---------------------------------------------------------------------------
if keys="$(git ls-files | grep -E '\.(pem|key|p12|pfx)$|id_rsa|id_ed25519' || true)"; then
    if [[ -n "${keys}" ]]; then
        fail "key material is tracked: ${keys}"
    else
        pass "no key material is tracked"
    fi
fi

if grep -rlE 'BEGIN (RSA |OPENSSH |EC |DSA )?PRIVATE KEY' --exclude-dir=.git . >/dev/null 2>&1; then
    fail "a PEM private key block is present in the working tree"
else
    pass "no PEM private key blocks in the tree"
fi

# ---------------------------------------------------------------------------
# 4. .gitignore actually protects secrets
# ---------------------------------------------------------------------------
# Asserting the *behaviour*, not the presence of a line, because a later
# negation rule can silently re-include a pattern.
for probe in .env .env.prod secrets/x.txt id_ed25519 tls/server.key; do
    mkdir -p "$(dirname "${probe}")" 2>/dev/null || true
    if git check-ignore -q "${probe}"; then
        pass ".gitignore excludes ${probe}"
    else
        fail ".gitignore does NOT exclude ${probe}"
    fi
done
rmdir secrets tls 2>/dev/null || true

# The example files must survive the ignore rules, or nobody can bootstrap.
for keep in .env.example .env.prod.example; do
    if git check-ignore -q "${keep}"; then
        fail "${keep} is ignored but must be tracked"
    else
        pass "${keep} is tracked"
    fi
done

# ---------------------------------------------------------------------------
# 5. Production configuration must not weaken security
# ---------------------------------------------------------------------------
if grep -qE '^ODOO_LIST_DB=True' .env.prod.example; then
    fail ".env.prod.example enables the database manager"
else
    pass ".env.prod.example keeps the database manager disabled"
fi

if grep -qE '^ODOO_LIST_DB=True' .env.qa.example; then
    fail ".env.qa.example enables the database manager"
else
    pass ".env.qa.example keeps the database manager disabled"
fi

# ---------------------------------------------------------------------------
# 6. The database must never publish a port
# ---------------------------------------------------------------------------
if awk '/^  db:/,/^  [a-z]+:/' compose.yml | grep -qE '^\s+ports:'; then
    fail "compose.yml publishes a database port"
else
    pass "compose.yml does not publish a database port"
fi

# ---------------------------------------------------------------------------
# 7. The image must not run as root
# ---------------------------------------------------------------------------
# The LAST USER instruction wins; an image can drop to a user and be switched
# back to root by a later layer.
last_user="$(grep -E '^USER ' docker/odoo/Dockerfile | tail -1 | awk '{print $2}')"
if [[ "${last_user}" == "odoo" ]]; then
    pass "Dockerfile ends as USER odoo"
else
    fail "Dockerfile's final USER is '${last_user}', expected odoo"
fi

# ---------------------------------------------------------------------------
# 8. No image may be referenced without a tag
# ---------------------------------------------------------------------------
for f in compose.yml compose.dev.yml compose.qa.yml compose.prod.yml; do
    if untagged="$(grep -nE '^\s+image:\s*[a-z0-9./-]+\s*$' "${f}" || true)"; then
        if [[ -n "${untagged}" ]]; then
            fail "${f} references an untagged image: ${untagged}"
        else
            pass "${f} tags every image"
        fi
    fi
done

# ---------------------------------------------------------------------------
echo
printf '  %s passed, %s failed\n' "${PASS}" "${FAIL}"
(( FAIL == 0 )) || exit 1
echo "  SECURITY ASSERTIONS PASSED"
