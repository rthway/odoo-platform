# Backup

## What an Odoo backup actually is

Two things, taken together:

1. **The PostgreSQL database** — every record, and the *references* to
   attachments
2. **The filestore** — the attachment bytes themselves, on disk

Restore one without the other and you get a database full of documents that
404. Both are captured in every backup set.

### Ordering matters

`backup.sh` captures the **filestore first, then the database**. Odoo writes
the file before committing the row, so:

- a file with no row is harmless garbage
- a row with no file is a broken attachment

Taking the filestore first makes the harmless case the possible one.

## Schedule

| Job | When | What |
|---|---|---|
| Backup | Daily 02:15 UTC | Database, filestore, configuration |
| Verification | Weekly, Sunday 04:00 | **Real restore** into a throwaway container |
| Pruning | Daily 05:30 | Apply retention |

Pruning runs **after** both, never before. Pruning first could delete the last
good set before a new one exists.

## A backup set

```
/var/backups/odoo/prod/20260903T021500Z_daily/
├── database.dump.age      pg_dump -Fc, age-encrypted
├── filestore.tar.gz.age   attachments
├── config.tar.gz.age      compose files and config (never .env)
├── manifest.json          SHA-256 of every file, sizes, image tag, duration
└── verification.json      present only after a passing restore test
```

`pg_dump -Fc` (custom format) is used rather than plain SQL because it is
compressed and supports selective and parallel restore. A plain dump supports
neither, which matters when the RTO is being measured in minutes.

## Integrity, and why checksums are not enough

Two levels, and only the second is evidence:

```bash
# Fast. Proves the bytes on disk are intact. Proves NOTHING about
# whether PostgreSQL can read them.
./scripts/verify-backup.sh -s <set> --checksums

# Slow. Restores into a THROWAWAY container and queries real Odoo tables.
# This is the one that counts.
./scripts/verify-backup.sh -s <set> --restore
```

The restore test starts a disposable PostgreSQL container, restores the dump,
and then asserts the result is a real Odoo database — over 50 public tables,
`res_users` / `res_company` / `ir_module_module` present, and at least one
installed module. A restore that "succeeds" into an empty database is not a
restore.

It touches no existing database, volume or running stack, and records the
measured restore duration, which is what feeds the RTO.

`backup.sh` refuses to accept a dump that lacks the `PGDMP` header. A
truncated dump that exists is worse than no dump at all, because it creates
false confidence.

## Retention

| | DEV | QA | PROD |
|---|---|---|---|
| Daily | 3 | 7 | 14 |
| Weekly | 1 | 2 | 8 |
| Monthly | 0 | 0 | 12 |

Grandfather-father-son: daily by age, weekly on Mondays, monthly on the 1st.

Two safety properties, both tested:

- **The newest set is never deleted**, whatever the policy says — a retention
  bug must not be able to leave an environment with zero backups
- Sets carrying a passing `verification.json` are protected
- `--dry-run` is the default; deleting requires `--apply`

```bash
./scripts/prune-backups.sh -e prod            # shows what would go
./scripts/prune-backups.sh -e prod --apply
```

## Encryption

Backups are encrypted at rest with [age](https://age-encryption.org):

```bash
age-keygen -o backup-key.txt          # keep the private half OFF these servers
# public half -> BACKUP_AGE_RECIPIENT in .env
```

`backup.sh` **refuses to write an unencrypted backup** when a recipient is
configured but `age` is missing, rather than silently degrading.

> Store the private key somewhere that survives losing this infrastructure. An
> encrypted backup whose key was only on the failed server is not a backup.

## 3-2-1

The rule: **3** copies, on **2** media, with **1** off-site.

| Copy | Where | Status |
|---|---|---|
| 1 | Live database on PROD .231 | — |
| 2 | Backup set on OPS .232 | Configured |
| 3 | Off-site | **NOT CONFIGURED** |

> ⚠ **PROD → OPS is not disaster recovery.** Both machines are in the same
> infrastructure. A site-level event — a datacentre fire, a compromised
> hypervisor, an account takeover — takes the backups with the primary.

To enable the third copy, set `BACKUP_OFFSITE_TARGET` to an rclone remote:

```bash
rclone config                     # e.g. S3, B2, or an SFTP host elsewhere
# .env:
BACKUP_OFFSITE_TARGET=remote:odoo-backups
```

`backup.sh` then replicates each set and **fails the job** if replication
fails, rather than reporting success for a backup that is not 3-2-1 compliant.

Until then the platform has a documented single-site failure mode. It is
listed as outstanding in the README rather than quietly omitted.

## Monitoring

`backup.sh` writes Prometheus metrics through node_exporter's textfile
collector, so a backup system that quietly stopped becomes an alert instead of
a discovery made during a restore:

| Metric | Alert |
|---|---|
| `odoo_backup_last_success_timestamp_seconds` | Critical above 26h |
| `odoo_backup_verify_last_success_timestamp_seconds` | Warning above 30 days |
| `odoo_backup_duration_seconds` | Info above 1h |
| `odoo_backup_size_bytes` | Watch for sudden drops |

There is also a `BackupMissingEntirely` alert for the metric being absent —
because "no data" and "everything is fine" look identical on a dashboard.

## Manual backup

```bash
cd /opt/odoo-platform
./scripts/backup.sh -e prod -l manual
./scripts/verify-backup.sh -s <printed path> --restore
```

`backup.sh` prints the set directory as its last line, which is how the
deployment workflow captures it.

## Current status

> No backup has ever been taken from a real database, because no environment
> has been deployed. The scripts are exercised on every pull request against a
> real Odoo and PostgreSQL in CI — including a full backup and restore round
> trip — but that is not the same as production data.
