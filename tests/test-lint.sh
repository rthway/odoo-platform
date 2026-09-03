#!/usr/bin/env bash
# ===========================================================================
# tests/test-lint.sh - lint checks runnable without a network
# ===========================================================================
# Mirrors what CI's lint job enforces, so a developer can get the same answer
# before pushing. Tools that are absent are SKIPPED and reported as skipped,
# never silently treated as passing.
# ===========================================================================
set -Eeuo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_DIR}"

PASS=0
FAIL=0
SKIP=0
pass() { printf '  PASS  %s\n' "$*"; PASS=$(( PASS + 1 )); }
fail() { printf '  FAIL  %s\n' "$*"; FAIL=$(( FAIL + 1 )); }
skip() { printf '  SKIP  %s\n' "$*"; SKIP=$(( SKIP + 1 )); }

echo "== Lint =="

# --- Shell syntax (bash is always present) ---------------------------------
syntax_bad=0
for f in scripts/*.sh tests/*.sh docker/odoo/*.sh; do
    bash -n "${f}" 2>/dev/null || { fail "${f} has a syntax error"; syntax_bad=1; }
done
(( syntax_bad == 0 )) && pass "every shell script parses"

# --- Executable bits -------------------------------------------------------
notexec=""
for f in scripts/*.sh tests/*.sh docker/odoo/*.sh; do
    [[ -x "${f}" ]] || notexec="${notexec} ${f}"
done
if [[ -n "${notexec}" ]]; then
    fail "not executable:${notexec}"
else
    pass "every shell script is executable"
fi

# --- Shebangs --------------------------------------------------------------
badshebang=""
for f in scripts/*.sh tests/*.sh docker/odoo/*.sh; do
    head -1 "${f}" | grep -qE '^#!/usr/bin/env (bash|sh)$' || badshebang="${badshebang} ${f}"
done
if [[ -n "${badshebang}" ]]; then
    fail "missing or non-portable shebang:${badshebang}"
else
    pass "every script has a portable shebang"
fi

# --- Strict mode -----------------------------------------------------------
# An unset variable in a deploy or backup script must abort, not expand to the
# empty string and quietly do the wrong thing.
nostrict=""
for f in scripts/*.sh tests/*.sh; do
    grep -qE '^set -[A-Za-z]*e[A-Za-z]*u' "${f}" || nostrict="${nostrict} ${f}"
done
if [[ -n "${nostrict}" ]]; then
    fail "missing 'set -eu':${nostrict}"
else
    pass "every script enables strict mode"
fi

# --- shellcheck ------------------------------------------------------------
if command -v shellcheck >/dev/null 2>&1; then
    if shellcheck -x -S warning scripts/*.sh tests/*.sh docker/odoo/*.sh; then
        pass "shellcheck reports no warnings"
    else
        fail "shellcheck reported problems"
    fi
else
    skip "shellcheck is not installed (CI runs it)"
fi

# --- yamllint --------------------------------------------------------------
if command -v yamllint >/dev/null 2>&1; then
    if yamllint -c .yamllint .github/ monitoring/ infrastructure/ ./*.yml; then
        pass "yamllint is clean"
    else
        fail "yamllint reported problems"
    fi
else
    skip "yamllint is not installed (CI runs it)"
fi

# --- YAML parses regardless of yamllint ------------------------------------
PYTHON=""
for _c in python3 python; do
    if "${_c}" -c 'import sys; sys.exit(0 if sys.version_info[0] == 3 else 1)' >/dev/null 2>&1; then
        PYTHON="${_c}"
        break
    fi
done

if [[ -n "${PYTHON}" ]]; then
    if "${PYTHON}" - <<'PY'
import glob, sys, yaml

bad = []
patterns = ["*.yml", ".github/workflows/*.yml", "monitoring/**/*.yml", "infrastructure/**/*.yml"]
seen = set()
for pattern in patterns:
    for path in glob.glob(pattern, recursive=True):
        if path in seen:
            continue
        seen.add(path)
        try:
            yaml.safe_load(open(path, encoding="utf-8"))
        except Exception as exc:
            bad.append(f"{path}: {exc}")

for b in bad:
    print(f"    {b}")
print(f"    parsed {len(seen)} YAML files")
sys.exit(1 if bad else 0)
PY
    then
        pass "every YAML file parses"
    else
        fail "at least one YAML file does not parse"
    fi
else
    skip "no working python3 for the YAML parse check"
fi

# --- hadolint --------------------------------------------------------------
if command -v hadolint >/dev/null 2>&1; then
    if hadolint --config .hadolint.yaml docker/odoo/Dockerfile; then
        pass "hadolint is clean"
    else
        fail "hadolint reported problems"
    fi
else
    skip "hadolint is not installed (CI runs it)"
fi

# ---------------------------------------------------------------------------
echo
printf '  %s passed, %s failed, %s skipped\n' "${PASS}" "${FAIL}" "${SKIP}"
(( FAIL == 0 )) || exit 1
echo "  LINT PASSED"
