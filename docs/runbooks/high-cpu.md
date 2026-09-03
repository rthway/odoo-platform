# Runbook: high CPU or slow response

**Alerts:** `HighCPU`, `OdooSlow`, `HighMemory`
**Severity:** SEV2, or SEV1 if production is effectively unusable.

```bash
ssh deploy@<host>
cd /opt/odoo-platform
E=prod; DC="docker compose -f compose.yml -f compose.$E.yml"
```


## 1. What is consuming it?

```bash
docker stats --no-stream
top -b -n1 | head -15
uptime                    # load average against core count
```

| Consumer | Go to |
|---|---|
| `db` | Step 2 |
| `odoo` | Step 3 |
| Something else | A neighbour process, or the host is undersized |

## 2. PostgreSQL

```bash
# Cumulative cost - the query burning the most total time
$DC exec -T db psql -U odoo_prod -d odoo_prod -c \
  "SELECT calls, round(mean_exec_time::numeric,1) AS avg_ms,
          round(total_exec_time::numeric,0) AS total_ms, left(query,80)
   FROM pg_stat_statements ORDER BY total_exec_time DESC LIMIT 10;"

# What is running right now
$DC exec -T db psql -U odoo_prod -d odoo_prod -c \
  "SELECT pid, now()-query_start AS duration, state, left(query,70)
   FROM pg_stat_activity WHERE state='active' ORDER BY duration DESC;"
```

A single runaway query can be terminated:

```bash
$DC exec -T db psql -U odoo_prod -d odoo_prod -c "SELECT pg_cancel_backend(<pid>);"
# pg_terminate_backend only if cancel does not work
```

Check the cache hit ratio on the PostgreSQL dashboard. Below 0.95 usually
means `shared_buffers` is too small, or a query is sequentially scanning a
table that needs an index.

## 3. Odoo

```bash
$DC logs --since 15m odoo | grep -iE 'slow|timeout|limit'
```

| Cause | Sign | Action |
|---|---|---|
| Too few workers | Sustained high CPU under normal traffic | Raise `ODOO_WORKERS` |
| Worker recycling | Repeated `limit_memory_soft` messages | Normal, unless constant |
| A heavy cron job | Load spikes on a schedule | Reschedule it |
| Import or report | One long request | Usually transient |
| Scraping or attack | High request rate from few addresses | Check nginx logs |

```bash
# Top client addresses in the last 10k requests
$DC logs --tail 10000 proxy | jq -r '.remote_addr' 2>/dev/null | sort | uniq -c | sort -rn | head
```

nginx already rate-limits `/web/login` to 6 requests per minute per address.

## 4. Worker sizing

```bash
nproc
grep ODOO_WORKERS .env
```

`(2 × vCPU) + 1`. More workers than that causes context switching, not
throughput — and each worker opens up to `ODOO_DB_MAXCONN` connections, so
raising it can exhaust `max_connections` instead.

```bash
vi .env                     # adjust ODOO_WORKERS
$DC up -d odoo
./scripts/healthcheck.sh -e $E
```

## 5. If it is memory

```bash
free -h
docker inspect --format '{{.State.OOMKilled}}' "$($DC ps -q odoo)"
```

`limit_memory_soft` must stay **below** `limit_memory_hard`, and the hard
limit must stay below the container's memory limit — otherwise Docker kills
the worker before Odoo can recycle it gracefully.
`tests/test-config.sh` asserts the first of those.
