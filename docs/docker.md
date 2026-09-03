# Docker

## Image strategy

One image, built once, promoted unchanged.

```
docker.io/rthway/odoo-platform:2026.09.03-a1b2c3d
                               │          │
                               │          └── short commit SHA
                               └── UTC build date (CalVer)
```

Also published:

| Tag | Purpose |
|---|---|
| `<CalVer>-<sha>` | **The contract.** Immutable; this is what gets deployed |
| `sha-<sha>` | Look up an image from a commit |
| `latest` | From `main` only, for humans. **Nothing deploys from it** |

`scripts/deploy.sh` refuses `latest` outright. A mutable tag means two hosts
pulling "the same" tag can legitimately get different images, which destroys
the promotion guarantee.

## OCI labels

```bash
docker inspect rthway/odoo-platform:2026.09.03-a1b2c3d \
  --format '{{json .Config.Labels}}' | jq
```

`org.opencontainers.image.revision` carries the exact commit. Build verifies
it matches `github.sha` and fails if not — provenance that is not checked is
provenance that drifts.

## Compose layering

```
compose.yml               base: db, odoo, proxy, networks, volumes
  ├── compose.dev.yml     host addon mount, debug logging, threaded
  ├── compose.qa.yml      production worker model, list_db off
  └── compose.prod.yml    resource limits, no-new-privileges, read-only proxy
```

The base is never used alone in QA or PROD:

```bash
docker compose -f compose.yml -f compose.prod.yml up -d
```

### Network design

| Network | Carries | Notes |
|---|---|---|
| `frontend` | proxy ↔ odoo | Bridge |
| `backend` | odoo ↔ db | **`internal: true` — no route off the host** |

### Volumes

| Volume | Holds | Loss means |
|---|---|---|
| `db-data` | PostgreSQL | Total data loss |
| `odoo-filestore` | Attachments | Every document 404s |
| `wal-archive` | WAL segments | No point-in-time recovery |
| `nginx-cache` | Cached assets | Nothing; regenerated |
| `certbot-webroot` | ACME challenges | Renewal fails |

## The nginx envsubst trap

nginx's official entrypoint renders `/etc/nginx/templates/*.template` with
`envsubst`. **By default it substitutes every `$variable` it finds** — which
would blank `$host`, `$remote_addr` and `$proxy_add_x_forwarded_for` and break
proxying in a way that looks like an Odoo bug.

`compose.yml` therefore sets:

```yaml
NGINX_ENVSUBST_FILTER: "^ODOO_DOMAIN$$"
```

`tests/test-config.sh` asserts this is present. Do not remove it.

## Build

```bash
docker build -f docker/odoo/Dockerfile \
  --build-arg BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --build-arg VCS_REF="$(git rev-parse HEAD)" \
  --build-arg VERSION="$(date -u +%Y.%m.%d)-$(git rev-parse --short HEAD)" \
  -t odoo-platform:local .
```

In practice you should not need this: CI builds the images that get deployed,
and a locally built image can never be promoted.

## Security properties

- Final `USER odoo` — never root. Asserted in CI and in `tests/test-security.sh`
- `no-new-privileges` in production
- nginx runs `read_only` in production with explicit tmpfs mounts
- Odoo cannot be read-only: it writes the filestore and session data
- Base images pinned to dated tags, never `latest`
- Bounded json-file logging on every service, so a chatty container cannot
  fill the disk and take the host down with it
