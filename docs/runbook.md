# Runbook

Routine operations, with real commands. Everything assumes:

```bash
ssh deploy@<host>
cd /opt/odoo-platform
E=prod            # or dev / qa
DC="docker compose -f compose.yml -f compose.$E.yml"
```

---

## Deploy

```bash
# Preferred: through the pipeline
gh workflow run deploy-prod.yml -f image_tag=2026.09.03-a1b2c3d
# then approve in Actions -> Review deployments

# On the host, incidents only
./scripts/deploy.sh -e prod -t 2026.09.03-a1b2c3d
```

## Roll back

```bash
./scripts/rollback.sh -e prod --reason "checkout errors after 1.4.0"
./scripts/rollback.sh -e prod -t 2026.09.01-9f8e7d6 --reason "..."
```

Read [`rollback.md`](rollback.md) first if a migration ran.

## What is running?

```bash
cat .deploy-state/current
tail -20 .deploy-state/history.log
$DC ps
docker inspect --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' \
  "$(docker compose -f compose.yml -f compose.$E.yml images -q odoo)"
```

## Restart Odoo

```bash
$DC restart odoo          # keeps the database up
./scripts/healthcheck.sh -e $E
```

If it will not start:

```bash
$DC logs --tail 100 odoo
$DC config          # confirm the resolved configuration is what you expect
```

## Restart PostgreSQL

```bash
# Stop the application first. Restarting the database underneath a live Odoo
# leaves it with a pool of dead connections.
$DC stop odoo
$DC restart db
$DC exec -T db pg_isready -U odoo_prod -d odoo_prod
$DC start odoo
./scripts/healthcheck.sh -e $E
```

## Restart everything

```bash
$DC down            # NOT -v, which would delete the volumes
$DC up -d
./scripts/healthcheck.sh -e $E
```

> Never `docker compose down -v` on an environment holding real data. `-v`
> removes the volumes, which means the database and the filestore.

## Check logs

```bash
$DC logs --tail 100 -f odoo
$DC logs --since 30m odoo | grep -iE 'error|traceback'
$DC logs --tail 200 db
$DC logs --tail 200 proxy
```

Centrally, in Grafana → Explore → Loki:

```logql
{environment="prod", service="odoo"} |= "ERROR"
```

## Check health

```bash
./scripts/healthcheck.sh -e prod        # containers, restarts, DB, HTTP
./tests/test-smoke.sh    -e prod        # HTTP behaviour and security headers
./tests/test-integration.sh -e prod     # ORM, filestore, sessions, cron
```

## Check Grafana / Prometheus

```bash
ssh -L 3000:127.0.0.1:3000 -L 9090:127.0.0.1:9090 -L 9093:127.0.0.1:9093 \
    deploy@157.10.100.232
```

- Grafana <http://localhost:3000>
- Prometheus targets <http://localhost:9090/targets> — all four hosts must be `UP`
- Firing alerts <http://localhost:9090/alerts>
- Alertmanager <http://localhost:9093>

## Check Docker

```bash
docker ps -a
docker stats --no-stream
docker system df                 # where the disk went
docker inspect --format '{{.State.Health.Status}} {{.RestartCount}}' <container>
```

## Take a backup

```bash
./scripts/backup.sh -e prod -l manual
./scripts/verify-backup.sh -s <printed path> --restore
```

## Restore a backup

```bash
ls -1dt /var/backups/odoo/prod/*/ | head -5
./scripts/verify-backup.sh -s <set> --restore        # verify BEFORE restoring

# Rehearse on QA whenever possible
./scripts/restore.sh -e qa -s <set>

# Production: requires the flag AND typing the database name
./scripts/restore.sh -e prod -s <set> --i-understand-this-destroys-prod
```

## Recover production

See [`disaster-recovery.md`](disaster-recovery.md). Summary:

```bash
ansible-playbook site.yml --limit prod        # rebuild the host
./scripts/deploy.sh -e prod -t <tag from history.log>
./scripts/restore.sh -e prod -s <verified set> --i-understand-this-destroys-prod
./scripts/healthcheck.sh -e prod
```

## Rotate secrets

See [`security.md`](security.md#rotation).

## Renew SSL

Certbot renews automatically. To check and force:

```bash
certbot certificates
certbot renew --dry-run
certbot renew --force-renewal
cp /etc/letsencrypt/live/<domain>/fullchain.pem config/nginx/tls/
cp /etc/letsencrypt/live/<domain>/privkey.pem   config/nginx/tls/
$DC exec proxy nginx -s reload

# Confirm what is actually being served
echo | openssl s_client -connect <domain>:443 2>/dev/null | openssl x509 -noout -dates
```

## Investigate high CPU

```bash
docker stats --no-stream
top -b -n1 | head -20

# Which query? pg_stat_statements is enabled for exactly this.
$DC exec -T db psql -U odoo_prod -d odoo_prod -c \
  "SELECT calls, round(mean_exec_time::numeric,1) AS avg_ms,
          round(total_exec_time::numeric,0) AS total_ms, left(query,90) AS query
   FROM pg_stat_statements ORDER BY total_exec_time DESC LIMIT 10;"

# Long-running queries right now
$DC exec -T db psql -U odoo_prod -d odoo_prod -c \
  "SELECT pid, now()-query_start AS duration, state, left(query,80)
   FROM pg_stat_activity WHERE state='active' ORDER BY duration DESC;"
```

Full procedure: [`runbooks/high-cpu.md`](runbooks/high-cpu.md).

## Investigate high disk

```bash
df -h
du -sh /var/lib/docker /var/backups/odoo /var/log | sort -h
docker system df

# Database and largest tables
$DC exec -T db psql -U odoo_prod -d odoo_prod -c \
  "SELECT pg_size_pretty(pg_database_size(current_database()));"
$DC exec -T db psql -U odoo_prod -d odoo_prod -c \
  "SELECT relname, pg_size_pretty(pg_total_relation_size(relid)) AS size
   FROM pg_catalog.pg_statio_user_tables
   ORDER BY pg_total_relation_size(relid) DESC LIMIT 10;"

# Safe reclamation, in order of preference
docker image prune -af --filter 'until=168h'
./scripts/prune-backups.sh -e prod           # dry run first
./scripts/prune-backups.sh -e prod --apply
```

Full procedure: [`runbooks/disk-full.md`](runbooks/disk-full.md).

## Investigate Odoo errors

```bash
$DC logs --since 1h odoo | grep -B5 -A20 Traceback | head -60

# Is it really the database?
$DC exec -T db psql -U odoo_prod -d odoo_prod -c \
  "SELECT count(*) FROM pg_stat_activity;"
$DC logs --since 1h db | grep -i error

# Was something deployed just before it started?
tail -5 .deploy-state/history.log
```

## Run a migration

```bash
./scripts/migrate.sh -e qa -m all            # rehearse on QA first, always
./scripts/migrate.sh -e prod -m sale,stock   # requires a fresh verified backup
```

## Scale workers

```bash
nproc                                  # workers should be (2 x vCPU) + 1
vi .env                                # ODOO_WORKERS=...
$DC up -d odoo
./scripts/healthcheck.sh -e $E
```

Remember `max_connections` in PostgreSQL must exceed
`workers × ODOO_DB_MAXCONN` plus cron threads and admin headroom.

---

## Server audit

Not yet performed — no SSH access was available. Run on each host and record
the output in [`infrastructure.md`](infrastructure.md):

```bash
hostname; cat /etc/os-release; uname -a
nproc; free -h; df -h
docker version; docker compose version
systemctl --failed
ss -tulpn
ufw status verbose
docker ps -a; docker volume ls; docker network ls
```

## Bringing the platform online

In order:

1. **Provision SSH** — create the `deploy` account on all four hosts, install
   the public key, and record host keys for `SSH_KNOWN_HOSTS`.
2. **Audit** — run the block above; correct the capacity figures.
3. **Configure GitHub** — environments, secrets, variables, branch protection
   ([`ci-cd.md`](ci-cd.md)).
4. **Provision** — `ansible-playbook site.yml --limit dev --check`, then apply;
   then QA, then OPS, then PROD.
5. **First build** — merge to `develop` and let Build produce a scanned image.
6. **DEV** — deploy, initialise the database, verify.
7. **QA** — promote the same tag; run integration and Odoo tests.
8. **Monitoring** — confirm all four targets are `UP` and Loki has labels.
9. **Backups** — run one manually, then `verify-backup.sh --restore`.
10. **Rehearse rollback and restore on QA** before production carries data.
11. **Off-site backups** — configure `BACKUP_OFFSITE_TARGET`; until then 3-2-1
    is not satisfied.
12. **PROD** — deploy only after the steps above have all passed.
