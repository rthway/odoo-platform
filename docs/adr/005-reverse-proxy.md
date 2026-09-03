# 005. nginx as the only ingress

**Status:** Accepted
**Date:** 2026-09-03

## Context

Odoo can serve HTTP directly, but it should not: it has no TLS
termination worth using, no rate limiting, and no way to add security headers
or block sensitive endpoints.

## Decision

Put nginx in front as the **only** ingress. Odoo and PostgreSQL publish
no host ports at all. nginx terminates TLS, sets security headers, rate-limits
authentication endpoints, blocks `/web/database/*`, and proxies websockets to
Odoo's gevent port.

## Consequences

Positive: one place for TLS, headers and rate limits. The database
manager is blocked independently of Odoo's own configuration, so a single
misconfiguration is not an exposure. Static assets are cached, removing load
from the workers.

Negative: another component. `proxy_mode=True` must be set in Odoo or it
generates `http://` URLs behind TLS — a subtle failure that shows up in
password-reset emails. `tests/test-integration.sh` asserts it.

## Alternatives considered

**Odoo directly on 443** — no rate limiting, no header control, and TLS
handled by an application server.

**Traefik or Caddy** — automatic certificates are attractive, but nginx's
behaviour under load is better understood and the rate-limiting configuration
is more explicit.
