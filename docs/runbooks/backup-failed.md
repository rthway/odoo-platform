# Runbook: backup failed or stale

**Alerts:** `BackupStale`, `BackupMissingEntirely`, `BackupRestoreNeverVerified`,
`PostgreSQLReplicationOrWALStalled`
**Severity:** SEV2 — every hour without a backup degrades the recovery point.

```bash
ssh deploy@<host>
cd /opt/odoo-platform
E=prod; DC="docker compose -f compose.yml -f compose.$E.yml"
```


## 1. What happened?

```bash
tail -50 /var/backups/odoo/backup.log
ls -1dt /var/backups/odoo/prod/*/ | head -5
crontab -l -u deploy | grep odoo-backup
```

## 2. Common causes

| Log line | Cause | Fix |
|---|---|---|
| `insufficient space` | Disk | [disk-full.md](disk-full.md) |
| `pg_dump failed` | Database unreachable | [database-unavailable.md](database-unavailable.md) |
| `dump lacks the PGDMP header` | Truncated dump | Usually disk; rerun after fixing |
| `age is missing` | Encryption tool absent | Install `age`; the script refuses to write plaintext |
| `off-site replication FAILED` | rclone or remote | Check `rclone config`, credentials |
| No log at all | Cron not installed | Re-run the `backup_schedule` role |

## 3. Run one now

```bash
./scripts/backup.sh -e prod -l manual
```

It prints the set directory as its final line.

## 4. Verify it

```bash
./scripts/verify-backup.sh -s <set> --checksums   # bytes intact
./scripts/verify-backup.sh -s <set> --restore     # actually restorable
```

Only the second proves anything. A checksum tells you the file has not rotted;
it says nothing about whether PostgreSQL can read it.

## 5. If the metric is missing entirely

`BackupMissingEntirely` means Prometheus sees no metric at all — backups may
never have run, or the textfile collector is misconfigured. "No data" and
"everything is fine" look identical on a dashboard, which is why this alert
exists.

```bash
ls -la /var/lib/node_exporter/textfile_collector/
cat /var/lib/node_exporter/textfile_collector/odoo_backup.prom
curl -s localhost:9100/metrics | grep odoo_backup
```

If the directory is missing or not writable by the deploy user, re-run the
`common` Ansible role.

## 6. WAL archiving stalled

```bash
$DC exec -T db psql -U odoo_prod -d odoo_prod -c "SELECT * FROM pg_stat_archiver;"
```

A rising `failed_count` means point-in-time recovery is broken **and**
`pg_wal` will grow until the disk fills. Check the archive directory exists
and is writable:

```bash
$DC exec -T db ls -ld /var/lib/postgresql/wal_archive
```

## 7. After recovery

- Confirm the next scheduled run succeeds; do not assume it
- Check the Backup dashboard shows the age dropping
- If backups were missing for a while, say so in the incident record: the
  recovery point was degraded for that entire period
