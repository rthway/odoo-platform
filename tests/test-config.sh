#!/usr/bin/env bash
# ===========================================================================
# tests/test-config.sh - configuration correctness, without running anything
# ===========================================================================
# Catches the class of mistake that is invisible to a linter but fatal at
# runtime: a placeholder nobody substitutes, an overlay that silently drops a
# setting, a soft memory limit above the hard limit.
# ===========================================================================
set -Eeuo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_DIR}"

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

PASS=0
FAIL=0
pass() { printf '  PASS  %s\n' "$*"; PASS=$(( PASS + 1 )); }
fail() { printf '  FAIL  %s\n' "$*"; FAIL=$(( FAIL + 1 )); }

echo "== Configuration tests =="

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# ---------------------------------------------------------------------------
# 1. Every Compose overlay resolves
# ---------------------------------------------------------------------------
for env in dev qa prod; do
    cp ".env.${env}.example" "${TMP}/.env.${env}"
    sed -i \
        -e 's/^POSTGRES_PASSWORD=$/POSTGRES_PASSWORD=test-only/' \
        -e 's/^ODOO_ADMIN_PASSWD=$/ODOO_ADMIN_PASSWD=test-only/' \
        -e 's/^ODOO_IMAGE_TAG=$/ODOO_IMAGE_TAG=0.0.0-test/' \
        -e 's/^ODOO_DOMAIN=$/ODOO_DOMAIN=example.invalid/' \
        "${TMP}/.env.${env}"

    if docker compose --env-file "${TMP}/.env.${env}" \
            -f compose.yml -f "compose.${env}.yml" config \
            > "${TMP}/resolved-${env}.yml" 2>"${TMP}/err-${env}"; then
        pass "compose.${env}.yml resolves"
    else
        fail "compose.${env}.yml does not resolve:"
        sed 's/^/          /' "${TMP}/err-${env}"
    fi
done

# ---------------------------------------------------------------------------
# 1b. The observability stack resolves
# ---------------------------------------------------------------------------
# Checked separately because it needs Grafana credentials that the
# application .env files do not carry. Its `:?` guards are deliberate: the
# stack must refuse to start rather than default to admin/admin.
cp .env.ops.example "${TMP}/.env.ops"
sed -i \
    -e 's/^GRAFANA_ADMIN_USER=$/GRAFANA_ADMIN_USER=test-only/' \
    -e 's/^GRAFANA_ADMIN_PASSWORD=$/GRAFANA_ADMIN_PASSWORD=test-only/' \
    "${TMP}/.env.ops"

if docker compose --env-file "${TMP}/.env.ops" -f compose.observability.yml config \
        > "${TMP}/resolved-ops.yml" 2>"${TMP}/err-ops"; then
    pass "compose.observability.yml resolves"
else
    fail "compose.observability.yml does not resolve:"
    sed 's/^/          /' "${TMP}/err-ops"
fi

# It must refuse to start without Grafana credentials, not default to them.
cp .env.ops.example "${TMP}/.env.ops-bare"
if docker compose --env-file "${TMP}/.env.ops-bare" -f compose.observability.yml config \
        >/dev/null 2>&1; then
    fail "observability stack resolves without Grafana credentials - it should refuse"
else
    pass "observability stack refuses to start without Grafana credentials"
fi

# Monitoring endpoints must stay bound to localhost by default.
if grep -qE '^MONITORING_BIND=127\.0\.0\.1' .env.ops.example; then
    pass "monitoring endpoints bind to localhost by default"
else
    fail "MONITORING_BIND is not 127.0.0.1 - Prometheus would be published unauthenticated"
fi

# ---------------------------------------------------------------------------
# 2. Environment isolation
# ---------------------------------------------------------------------------
if "${PYTHON}" - "${TMP}" <<'PY'
import pathlib, sys, yaml

tmp = pathlib.Path(sys.argv[1])
failures = []
databases = {}
projects = {}

for env in ("dev", "qa", "prod"):
    path = tmp / f"resolved-{env}.yml"
    if not path.exists():
        failures.append(f"{env}: no resolved config to check")
        continue
    cfg = yaml.safe_load(path.read_text())
    odoo = cfg["services"]["odoo"]
    envv = odoo["environment"]

    db = envv.get("ODOO_DB_NAME")
    if db in databases:
        failures.append(f"{env} and {databases[db]} share database '{db}'")
    databases[db] = env

    proj = cfg.get("name")
    if proj in projects:
        failures.append(f"{env} and {projects[proj]} share project name '{proj}'")
    projects[proj] = env

    if env in ("qa", "prod"):
        if str(envv.get("ODOO_LIST_DB")) != "False":
            failures.append(f"{env}: ODOO_LIST_DB must be False")
        binds = [v for v in odoo.get("volumes", []) if v.get("type") == "bind"]
        if binds:
            failures.append(f"{env}: host bind mounts present: {[b['source'] for b in binds]}")

    if "ports" in cfg["services"]["db"]:
        failures.append(f"{env}: the database publishes a port")

    # Memory limits must be coherent, or workers are killed before they can
    # recycle gracefully.
    soft = int(envv.get("ODOO_LIMIT_MEMORY_SOFT", 0))
    hard = int(envv.get("ODOO_LIMIT_MEMORY_HARD", 0))
    if soft and hard and soft >= hard:
        failures.append(f"{env}: limit_memory_soft ({soft}) >= hard ({hard})")

    # The backend network must stay internal in every environment.
    if not cfg["networks"]["backend"].get("internal"):
        failures.append(f"{env}: the backend network is not internal")

for f in failures:
    print(f"    {f}")
sys.exit(1 if failures else 0)
PY
then
    pass "environment isolation holds across dev/qa/prod"
else
    fail "environment isolation is violated"
fi

# ---------------------------------------------------------------------------
# 3. All three environments resolve to the SAME image
# ---------------------------------------------------------------------------
# The promotion model depends on it: if the overlays could change the image
# reference, "the same artifact everywhere" would be untrue.
images="$(grep -h 'image:.*odoo-platform' "${TMP}"/resolved-*.yml | sed 's/^ *//' | sort -u | wc -l)"
if [[ "${images}" == "1" ]]; then
    pass "dev, qa and prod all resolve to one identical image reference"
else
    fail "environments resolve to ${images} different image references"
    grep -h 'image:.*odoo-platform' "${TMP}"/resolved-*.yml | sort -u | sed 's/^/          /'
fi

# ---------------------------------------------------------------------------
# 4. The Odoo config template renders with no placeholder left behind
# ---------------------------------------------------------------------------
if command -v envsubst >/dev/null 2>&1; then
    HOST=db PORT=5432 USER=odoo PASSWORD=x \
    ODOO_DB_NAME=odoo_test ODOO_DB_MAXCONN=32 ODOO_ADMIN_PASSWD=y \
    ODOO_WORKERS=2 ODOO_MAX_CRON_THREADS=1 \
    ODOO_LIMIT_MEMORY_SOFT=2147483648 ODOO_LIMIT_MEMORY_HARD=2684354560 \
    ODOO_LIMIT_TIME_CPU=60 ODOO_LIMIT_TIME_REAL=120 ODOO_LIMIT_REQUEST=8192 \
    ODOO_LIST_DB=False ODOO_PROXY_MODE=True ODOO_LOG_LEVEL=info \
        envsubst < config/odoo/odoo.conf.tmpl > "${TMP}/odoo.conf"

    # Only real ${VAR} placeholders matter; prose in comments does not.
    if leftover="$(grep -nE '\$\{[A-Z_]+\}' "${TMP}/odoo.conf" || true)"; then
        if [[ -n "${leftover}" ]]; then
            fail "odoo.conf still contains placeholders after rendering:"
            echo "${leftover}" | sed 's/^/          /'
        else
            pass "odoo.conf renders with every placeholder substituted"
        fi
    fi

    # The path is passed as an argument, not interpolated into the code: the
    # MSYS/Git-Bash shell rewrites POSIX paths in argv into native paths, but
    # leaves them untouched inside a -c string, where configparser would then
    # find nothing and return an empty config without raising.
    if "${PYTHON}" - "${TMP}/odoo.conf" <<'PY'
import configparser, pathlib, sys

path = pathlib.Path(sys.argv[1])
cfg = configparser.ConfigParser()
read = cfg.read(path)
# read() returns the files it managed to parse. An empty list means the file
# was never opened, which must fail loudly rather than pass by default.
assert read, f"configparser could not read {path}"

o = cfg["options"]
assert o["db_name"] == "odoo_test", o["db_name"]
assert o["dbfilter"] == "^odoo_test$", o["dbfilter"]
assert o["list_db"] == "False", o["list_db"]
assert o["proxy_mode"] == "True", o["proxy_mode"]
assert int(o["limit_memory_soft"]) < int(o["limit_memory_hard"])
assert o["logfile"] == "None", "Odoo must log to stdout for Docker/Loki"
PY
    then
        pass "rendered odoo.conf parses and its values are coherent"
    else
        fail "rendered odoo.conf is invalid or inconsistent"
    fi
else
    echo "  SKIP  envsubst is not installed"
fi

# ---------------------------------------------------------------------------
# 5. nginx must only substitute ODOO_DOMAIN
# ---------------------------------------------------------------------------
# Without the filter, nginx's entrypoint blanks $host and
# $proxy_add_x_forwarded_for, and proxying breaks in a way that looks like an
# application bug.
if grep -q 'NGINX_ENVSUBST_FILTER' compose.yml; then
    pass "compose.yml sets NGINX_ENVSUBST_FILTER"
else
    fail "NGINX_ENVSUBST_FILTER is missing - nginx would blank its own variables"
fi

# ---------------------------------------------------------------------------
# 6. Base images must be pinned
# ---------------------------------------------------------------------------
if grep -E '^FROM' docker/odoo/Dockerfile | grep -qE ':\$\{?ODOO_VERSION'; then
    default_ver="$(grep -E '^ARG ODOO_VERSION=' docker/odoo/Dockerfile | head -1 | cut -d= -f2)"
    if [[ "${default_ver}" == "latest" || -z "${default_ver}" ]]; then
        fail "ODOO_VERSION defaults to '${default_ver}'"
    else
        pass "Dockerfile pins the Odoo base image to ${default_ver}"
    fi
else
    fail "Dockerfile's FROM is not parameterised by ODOO_VERSION"
fi

for img in POSTGRES_VERSION NGINX_VERSION; do
    val="$(grep -E "^${img}=" .env.example | cut -d= -f2)"
    if [[ -z "${val}" || "${val}" == "latest" ]]; then
        fail "${img} is unpinned ('${val}')"
    else
        pass "${img} is pinned to ${val}"
    fi
done

# ---------------------------------------------------------------------------
echo
printf '  %s passed, %s failed\n' "${PASS}" "${FAIL}"
(( FAIL == 0 )) || exit 1
echo "  CONFIGURATION TESTS PASSED"
