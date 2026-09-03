# 002. Pin every image to a dated tag

**Status:** Accepted
**Date:** 2026-09-03

## Context

`odoo:18` moves. Two hosts pulling it a week apart legitimately get
different software, which silently breaks the promotion model — QA would no
longer be testing what production runs.

## Decision

Pin base images to dated tags (`odoo:18.0-20260817`,
`postgres:16.15-alpine3.24`, `nginx:1.31.4-alpine3.24`). Tag our own image
`<CalVer>-<short-sha>`. `latest` is published from `main` for humans only, and
`deploy.sh` **refuses** it.

## Consequences

Positive: what ran yesterday runs today. Production can name its exact
commit. Rollback targets a specific artifact rather than a moving name.

Negative: version bumps are a deliberate commit, so security updates require
action. Mitigated by Dependabot, weekly Trivy scans and scheduled rebuilds.

## Alternatives considered

**Floating tags** — convenient until an unannounced upstream change
breaks production at an unpredictable moment.

**Digest pinning everywhere** — maximally reproducible but unreadable; dated
tags plus a recorded digest at deploy time gives most of the benefit.
