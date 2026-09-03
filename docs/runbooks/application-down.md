# Runbook: application down

**Alerts:** `OdooDown`, `OdooDownProduction`, `ServerDown`, `ContainerDisappeared`
**Severity:** SEV1 in production.

```bash
ssh deploy@<host>
cd /opt/odoo-platform
E=prod; DC="docker compose -f compose.yml -f compose.$E.yml"
```


## 1. Confirm it is really down

Check from outside, the way a user does. A failing probe with a working site
means the monitoring path is broken, not the application.

```bash
curl -sv -o /dev/null -w '%{http_code}\n' https://<domain>/web/login
```

## 2. Was something just deployed?

```bash
tail -5 .deploy-state/history.log
```

If there was a deployment in the last hour, **roll back now and diagnose
afterwards**. Restoring service comes first.

```bash
./scripts/rollback.sh -e prod --reason "SEV1 application down"
```

## 3. Which layer is broken?

```bash
$DC ps
./scripts/healthcheck.sh -e prod
```

| Observation | Go to |
|---|---|
| No containers at all | Step 4 |
| `db` unhealthy | [database-unavailable.md](database-unavailable.md) |
| `odoo` restarting | Step 5 |
| All up but 502 | Step 6 |
| Host unreachable | [disaster-recovery.md](../disaster-recovery.md#scenario-5--total-host-loss) |

## 4. Nothing is running

```bash
systemctl status docker
systemctl status odoo-platform
df -h                       # a full disk stops Docker starting containers
$DC up -d
```

If the disk is full: [disk-full.md](disk-full.md).

## 5. Odoo is crash-looping

```bash
$DC logs --tail 100 odoo
docker inspect --format '{{.State.OOMKilled}} {{.RestartCount}}' \
  "$($DC ps -q odoo)"
```

| Log line | Meaning |
|---|---|
| `OOMKilled: true` | Memory limit hit; raise it or lower `ODOO_WORKERS` |
| `PostgreSQL ... not ready` | Database problem, not the application |
| `list_db=True is not permitted` | `.env` is wrong for this environment |
| `Registry not loaded` / import error | A module fails to import — roll back |

## 6. Containers healthy, users see 502

nginx is up and Odoo is not answering it.

```bash
$DC exec proxy nginx -t
$DC exec proxy wget -qO- http://odoo:8069/web/health
$DC logs --tail 50 proxy
```

If Odoo answers internally but not through nginx, restart the proxy. If it
does not answer internally, Odoo is still starting or is wedged — check its
log before restarting, so the cause is not lost.

## 7. Verify recovery

```bash
./scripts/healthcheck.sh -e prod
./tests/test-smoke.sh -e prod
curl -s -o /dev/null -w '%{http_code}\n' https://<domain>/web/login
```

## 8. Afterwards

Record the timeline and hold a review
([incident-response.md](../incident-response.md)). If detection was slower
than it should have been, that is an alerting gap and deserves an action item.
