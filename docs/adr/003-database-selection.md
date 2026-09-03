# 003. PostgreSQL in a container, one per environment

**Status:** Accepted
**Date:** 2026-09-03

## Context

Odoo requires PostgreSQL. The choice is where it runs and whether
environments share an instance.

## Decision

Run PostgreSQL 16 as a container on each application host, with its own
data volume, tuned config, WAL archiving and `pg_stat_statements`. Each
environment gets its **own instance and its own database**.

## Consequences

Positive: complete isolation — QA can never reach production data, which
is asserted in CI. Backup and restore are per-environment. Configuration is
version-controlled with the application.

Negative: three instances to patch. Memory tuning must respect the host, since
Odoo and PostgreSQL share it. No high availability — a host failure means a
restore.

## Alternatives considered

**A shared database server** — one misconfigured `.env` away from QA
writing to production. Rejected outright.

**Managed PostgreSQL** — better durability and failover, and worth revisiting;
not available in this environment.

**PostgreSQL on the host** — loses the config-as-code and pinning benefits.
