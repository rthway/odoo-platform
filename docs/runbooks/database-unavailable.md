# Runbook: database unavailable

**Alerts:** `PostgreSQLDown`, `PostgreSQLTooManyConnections`
**Severity:** SEV1 in production. Odoo cannot function without it.

```bash
ssh deploy@<host>
cd /opt/odoo-platform
E=prod; DC="docker compose -f compose.yml -f compose.$E.yml"
```


## 1. Is it running?

```bash
$DC ps db
$DC logs --tail 100 db
$DC exec -T db pg_isready -U odoo_prod -d odoo_prod
```

## 2. Container will not start

```bash
docker inspect --format '{{.State.ExitCode}} {{.State.Error}}' "$($DC ps -aq db)"
df -h
```

| Cause | Sign | Action |
|---|---|---|
| Disk full | `No space left on device` | [disk-full.md](disk-full.md) — urgent |
| Corrupt WAL | `invalid record length` | Escalate; do not improvise |
| Bad config | `unrecognized configuration parameter` | Fix `postgresql.conf`, restart |
| Permissions | `data directory has wrong ownership` | Do not chown blindly; escalate |

**A full disk on a database host risks data loss, not just downtime.** Treat it
as the most urgent case.

## 3. Running but refusing connections

Almost always connection exhaustion.

```bash
$DC exec -T db psql -U odoo_prod -d odoo_prod -c \
  "SELECT count(*) AS used, current_setting('max_connections') AS max FROM pg_stat_activity;"

$DC exec -T db psql -U odoo_prod -d odoo_prod -c \
  "SELECT state, count(*) FROM pg_stat_activity GROUP BY state;"
```

Many `idle in transaction` backends mean the application is opening
transactions and not closing them. Free them:

```bash
$DC exec -T db psql -U odoo_prod -d odoo_prod -c \
  "SELECT pg_terminate_backend(pid) FROM pg_stat_activity
   WHERE state='idle in transaction' AND state_change < now() - interval '10 minutes';"
```

That is a stopgap. The real fix is capacity:
`max_connections` must exceed `ODOO_WORKERS × ODOO_DB_MAXCONN` plus cron
threads plus admin headroom.

## 4. Locks

```bash
$DC exec -T db psql -U odoo_prod -d odoo_prod -c \
  "SELECT blocked.pid AS blocked_pid, blocking.pid AS blocking_pid,
          left(blocked.query,60) AS blocked_query
   FROM pg_stat_activity blocked
   JOIN pg_stat_activity blocking ON blocking.pid = ANY(pg_blocking_pids(blocked.pid))
   WHERE cardinality(pg_blocking_pids(blocked.pid)) > 0;"
```

Terminate the **blocking** process, not the blocked one — and only after
seeing what it is doing.

## 5. Suspected corruption

Stop writes, preserve evidence, then follow
[disaster-recovery.md](../disaster-recovery.md#scenario-3--database-corruption).

```bash
$DC stop odoo proxy
$DC exec -T db pg_dump -U odoo_prod -d odoo_prod -Fc \
  > /var/backups/odoo/corrupt-$(date +%s).dump
```

Do not restore a backup before capturing the current state. The damaged
database may hold data the backup does not.

## 6. Recovery

```bash
$DC start odoo proxy
./scripts/healthcheck.sh -e prod
```
