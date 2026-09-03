# 007. TLS 1.2+, HSTS, and no CSP for now

**Status:** Accepted
**Date:** 2026-09-03

## Context

Odoo handles business data and must be served over HTTPS with sensible
security headers. Content-Security-Policy is the usual recommendation.

## Decision

Serve TLS 1.2 and 1.3 only, with a modern cipher suite, HSTS,
`X-Content-Type-Options`, `X-Frame-Options: SAMEORIGIN`, `Referrer-Policy` and
a restrictive `Permissions-Policy`.

**Deliberately do not set Content-Security-Policy yet.**

## Consequences

Positive: strong transport security and the headers that matter most,
with no functional risk. `SAMEORIGIN` rather than `DENY` because Odoo embeds
its own iframes.

Negative: without CSP there is less defence against injected script. Accepted
knowingly rather than by omission, and recorded as outstanding in
`docs/security.md`.

HSTS is set **without** `preload`: preload lists are painful to leave, and the
domain is not final.

## Alternatives considered

**A strict CSP now** — Odoo's web client relies on inline scripts and
`eval`. A naive policy breaks the backend UI outright, and the usual response
is to weaken it to `unsafe-inline unsafe-eval`, which provides little real
protection while implying it does.

The correct path is a `Content-Security-Policy-Report-Only` rollout, gathering
violations from the real application first. That is the recommended next step,
not a permanent exemption.
