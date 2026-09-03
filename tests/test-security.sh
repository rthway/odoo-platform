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

# Scan TRACKED files only. What matters is what can reach the repository; a
# locally generated self-signed key for development is legitimate and lives
# in the working tree by design. Scanning the tree instead made this fail the
# moment scripts/gen-local-tls.sh was run.
pem_tracked=""
while IFS= read -r f; do
    [[ -f "${f}" ]] || continue
    if grep -qE 'BEGIN (RSA |OPENSSH |EC |DSA )?PRIVATE KEY' "${f}" 2>/dev/null; then
        pem_tracked="${pem_tracked} ${f}"
    fi
done < <(git ls-files)

if [[ -n "${pem_tracked}" ]]; then
    fail "a PEM private key is COMMITTED:${pem_tracked}"
else
    pass "no PEM private key is tracked by git"
fi

# Any key material sitting in the working tree must at least be ignored, so
# it cannot be swept up by `git add -A`.
unignored_keys=""
while IFS= read -r f; do
    git check-ignore -q "${f}" || git ls-files --error-unmatch "${f}" >/dev/null 2>&1 \
        || unignored_keys="${unignored_keys} ${f}"
done < <(find . -type f \( -name '*.pem' -o -name '*.key' -o -name 'id_rsa*' -o -name 'id_ed25519*' \) \
              -not -path './.git/*' 2>/dev/null)

if [[ -n "${unignored_keys}" ]]; then
    fail "untracked key material is NOT gitignored:${unignored_keys}"
else
    pass "any local key material is gitignored"
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

# Every example file must survive the ignore rules, or nobody can bootstrap
# an environment. Enumerated from disk rather than hardcoded: a hardcoded list
# is exactly how a newly added .env.<env>.example gets silently excluded and
# nobody notices until it is needed.
for keep in .env*.example; do
    [[ -f "${keep}" ]] || continue
    if git check-ignore -q "${keep}"; then
        fail "${keep} exists but .gitignore excludes it - it will never be committed"
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
