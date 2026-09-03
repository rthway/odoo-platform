# 004. pg_dump with verified restores, not pgBackRest

**Status:** Accepted
**Date:** 2026-09-03

## Context

The platform needs backups that are known to work. The brief suggested
pgBackRest, which offers incremental backup and integrated PITR.

## Decision

Use `pg_dump -Fc` plus a filestore tar, encrypted with age, with a
SHA-256 manifest — and a **weekly automated restore into a throwaway
container** as the primary evidence that backups work.

WAL archiving is enabled so PITR remains possible. pgBackRest is deferred, not
rejected.

## Consequences

Positive: few moving parts, and the restore path is the same one used in
an emergency, so it is exercised constantly — including on every pull request
in CI. `-Fc` supports selective and parallel restore. Encryption is simple to
reason about.

Negative: full dump each time, so backup size and duration grow with the
database. Dump-and-restore is slower than a physical backup at large sizes.
PITR is configured but unproven here.

Revisit when the database passes roughly 50 GB or when the RPO must drop below
an hour.

## Alternatives considered

**pgBackRest** — the better answer at scale, with incremental backups and
first-class PITR. Deferred because it adds a component to operate and the
current database size does not yet justify it. The trigger for revisiting is
recorded above.

**Filesystem snapshots** — fast, but tied to the storage layer and not
portable off-site.

**Odoo's built-in backup** — goes through HTTP, needs the database manager
enabled, and does not scale. Rejected: we deliberately block that endpoint.
