# 001. Docker Compose rather than Kubernetes

**Status:** Accepted
**Date:** 2026-09-03

## Context

Four servers run one application: Odoo, PostgreSQL and nginx per
environment, plus a monitoring host. The team is small and the same people
operate the platform out of hours.

The orchestration choice determines who can recover this system at 3am.

## Decision

Use **Docker Compose v2** with a base file and per-environment overlays,
driven by Ansible for host configuration and GitHub Actions for deployment.

## Consequences

Positive: an operator can read `compose.yml` and know exactly what runs.
Recovery is `docker compose up -d`. No control plane to keep alive, patch or
debug. Overlays give real environment separation with no templating language.

Negative: no automatic rescheduling if a host dies — recovery is the documented
manual procedure. No rolling deployment; there is a short restart. Scaling
beyond one host per environment would need revisiting.

## Alternatives considered

**Kubernetes** — would add etcd, a CNI, an ingress controller and a new
failure domain in exchange for scheduling this workload does not need. The
operational burden would exceed the application's.

**Docker Swarm** — closer in spirit, but effectively unmaintained.

**Plain systemd units** — no image immutability, and the promote-the-same-image
model would be much harder to guarantee.
