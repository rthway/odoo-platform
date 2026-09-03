# Development

## Prerequisites

Docker with Compose v2, Git, Python 3.12, and optionally shellcheck,
yamllint and hadolint (CI runs them regardless).

## Getting started

```bash
git clone https://github.com/rthway/odoo-platform.git
cd odoo-platform

cp .env.dev.example .env
./scripts/gen-secrets.sh dev        # prints to stdout; paste the values you need

docker compose -f compose.yml -f compose.dev.yml up -d
```

The image tag must exist. Either pull one CI built, or build locally:

```bash
docker build -f docker/odoo/Dockerfile -t odoo-platform:local .
# then in .env:  ODOO_IMAGE=odoo-platform  and  ODOO_IMAGE_TAG=local
```

Initialise the database — a fresh one has no schema at all:

```bash
docker compose -f compose.yml -f compose.dev.yml exec odoo \
  odoo --config=/etc/odoo/odoo.conf --database=odoo_dev --init=base --stop-after-init

docker compose -f compose.yml -f compose.dev.yml up -d
./scripts/healthcheck.sh -e dev
```

Odoo is on <http://localhost:8080>.

## What makes DEV different

| | DEV | QA and PROD |
|---|---|---|
| Addons | Bind-mounted from `./addons` | **From the image only** |
| Workers | 0 (threaded) | Multi-worker |
| `list_db` | True | False |
| Logging | debug | info / warn |

Threaded mode makes tracebacks linear and debugging sane. The bind mount means
editing a module and restarting the container is enough — no rebuild.

Neither is available in QA or PROD, deliberately: what QA tests must be
byte-identical to what production runs.

## Developing an addon

```bash
mkdir -p addons/my_module
# ... __init__.py, __manifest__.py, models/ ...

docker compose -f compose.yml -f compose.dev.yml exec odoo \
  odoo --config=/etc/odoo/odoo.conf --database=odoo_dev \
       --init=my_module --stop-after-init

docker compose -f compose.yml -f compose.dev.yml restart odoo
```

After changing Python, restart the container. After changing XML views, update
the module:

```bash
docker compose -f compose.yml -f compose.dev.yml exec odoo \
  odoo --config=/etc/odoo/odoo.conf --database=odoo_dev \
       --update=my_module --stop-after-init
```

Extra Python dependencies go in `requirements.txt` — **pinned**. An unpinned
dependency makes the image non-reproducible, which defeats the whole
promote-the-same-image model.

## Running tests

```bash
./tests/run-all.sh                          # no Docker needed
./tests/run-all.sh --with-runtime -e dev    # against the running stack

./tests/test-lint.sh
./tests/test-config.sh
./tests/test-security.sh
./tests/test-smoke.sh -e dev
./tests/test-integration.sh -e dev
./tests/test-odoo-modules.sh -e dev         # Odoo's own suite
```

`test-odoo-modules.sh` clones the database into a throwaway copy first,
because `--test-enable` writes and would otherwise leave test records behind.

Run `./tests/run-all.sh` before pushing. It is the same set CI runs, minus the
tools that need Linux.

## Useful commands

```bash
DC="docker compose -f compose.yml -f compose.dev.yml"

$DC logs -f odoo
$DC exec odoo odoo shell --config=/etc/odoo/odoo.conf --database=odoo_dev
$DC exec db psql -U odoo_dev -d odoo_dev
$DC restart odoo
$DC down            # keeps volumes
$DC down -v         # DELETES the database and filestore
```

## Resetting DEV

```bash
docker compose -f compose.yml -f compose.dev.yml down -v
docker compose -f compose.yml -f compose.dev.yml up -d
# then re-initialise as above
```

Safe in DEV. `-v` deletes volumes, so never run it anywhere holding real data.

## Before you push

1. `./tests/run-all.sh` passes
2. Commit messages follow Conventional Commits
   ([`git-workflow.md`](git-workflow.md))
3. No secrets — Gitleaks scans the full history, and it will find them
4. Any new script is executable and starts with `set -Eeuo pipefail`; CI
   asserts both
5. Docs updated if behaviour changed

## Common problems

| Symptom | Cause |
|---|---|
| `ODOO_IMAGE_TAG` required | `.env` has an empty tag; set one |
| Odoo exits immediately | Read `$DC logs odoo`; usually a missing required variable |
| `list_db=True is not permitted` | `ENVIRONMENT` is not `dev`; the entrypoint is refusing on purpose |
| Database does not exist | It was never initialised; run `--init=base` |
| Port 8080 in use | Change `HTTP_PORT` in `.env` |
| Addon changes ignored | Restart the container; update the module for XML |
