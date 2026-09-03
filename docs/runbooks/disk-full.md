# Runbook: disk filling or full

**Alerts:** `DiskSpaceLow` (80%), `DiskSpaceCritical` (90%), `DiskWillFillIn24Hours`
**Severity:** SEV2 at 80%, SEV1 at 95% or on a database host.

A full disk on a PostgreSQL host is not merely an outage — the database cannot
write WAL, and recovery can involve data loss. Act at 80%, not at 99%.

```bash
ssh deploy@<host>
cd /opt/odoo-platform
E=prod; DC="docker compose -f compose.yml -f compose.$E.yml"
```


## 1. Where has it gone?

```bash
df -h
du -sh /var/lib/docker /var/backups/odoo /var/log 2>/dev/null | sort -h
docker system df
```

## 2. Safe reclamation, in order

Each step is safe. Stop as soon as there is enough headroom.

```bash
# a. Old images. --filter until=168h protects the previous release image,
#    which rollback.sh depends on.
docker image prune -af --filter 'until=168h'

# b. Build cache
docker builder prune -af

# c. Stopped containers
docker container prune -f

# d. Journal logs
journalctl --vacuum-size=200M
```

## 3. Backups

```bash
./scripts/prune-backups.sh -e prod            # dry run, always first
./scripts/prune-backups.sh -e prod --apply
```

The script never deletes the newest set, nor any set with a passing
verification, whatever the policy says.

## 4. Container logs

```bash
du -sh /var/lib/docker/containers/*/*-json.log | sort -h | tail -5
```

If one is large, the json-file limits are not applying — check
`/etc/docker/daemon.json` and the `logging` block in `compose.yml`. Truncate
only as a last resort, and never with `rm` on a live log:

```bash
truncate -s 0 /var/lib/docker/containers/<id>/<id>-json.log
```

## 5. Database growth

```bash
$DC exec -T db psql -U odoo_prod -d odoo_prod -c \
  "SELECT pg_size_pretty(pg_database_size(current_database()));"

$DC exec -T db psql -U odoo_prod -d odoo_prod -c \
  "SELECT relname, pg_size_pretty(pg_total_relation_size(relid)) AS total
   FROM pg_catalog.pg_statio_user_tables
   ORDER BY pg_total_relation_size(relid) DESC LIMIT 10;"
```

`ir_attachment`, `mail_message` and `ir_logging` are the usual culprits.

Bloat from dead tuples:

```bash
$DC exec -T db psql -U odoo_prod -d odoo_prod -c \
  "SELECT relname, n_dead_tup, last_autovacuum FROM pg_stat_user_tables
   ORDER BY n_dead_tup DESC LIMIT 10;"
```

`VACUUM FULL` reclaims the most space but takes an **exclusive lock** — it is
an outage. Prefer plain `VACUUM`, or schedule the full one in a window.

## 6. WAL growth

```bash
docker volume inspect odoo-prod_wal-archive --format '{{.Mountpoint}}'
$DC exec -T db psql -U odoo_prod -d odoo_prod -c "SELECT * FROM pg_stat_archiver;"
```

A rising `failed_count` means archiving is broken and `pg_wal` will grow until
the disk fills. Fix archiving before pruning anything —
[backup-failed.md](backup-failed.md).

## 7. Prevention

- `DiskWillFillIn24Hours` is trend-based and fires long before the thresholds
- Weekly image prune, installed by the `docker` Ansible role
- Retention pruning runs daily
- Review the Infrastructure dashboard when adding data-heavy modules
