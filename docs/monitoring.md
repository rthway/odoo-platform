# Monitoring

## Stack

Everything runs on OPS `.232`, deliberately on a separate lifecycle from the
application. Monitoring that shares a host with Odoo goes down in exactly the
outage it exists to report.

| Component | Port | Purpose |
|---|---|---|
| Prometheus | 9090 | Metrics, rule evaluation |
| Grafana | 3000 | Dashboards |
| Alertmanager | 9093 | Routing, grouping, inhibition |
| Loki | 3100 | Logs |
| Blackbox | — | Probes Odoo the way a user reaches it |

Agents on DEV, QA and PROD: node_exporter (9100), cAdvisor (8081),
postgres_exporter (9187), promtail. All three exporters are reachable **only
from OPS**, enforced by ufw.

```bash
docker compose -f compose.observability.yml up -d
ssh -L 3000:127.0.0.1:3000 <user>@157.10.100.232
```

## Why blackbox probing matters

White-box metrics tell you the process is alive. A blackbox probe tells you a
user can actually reach it — which catches an expired certificate, a proxy
that stopped forwarding, or a firewall change, none of which show up in
container metrics.

`probe_success{service="odoo"}` is the closest single metric to "can people
work?", which is why it drives the paging alerts.

## What is collected

| Domain | Examples |
|---|---|
| Host | CPU, memory, disk, load, network, disk I/O saturation |
| Container | CPU, working-set memory, restarts, filesystem, network |
| PostgreSQL | Connections, size, transactions, locks, cache hit ratio, WAL archiving |
| Odoo | Availability, response time, HTTP status, certificate expiry |
| Backup | Last success, last verified restore, duration, size |

cAdvisor is extremely verbose, so `metric_relabel_configs` keeps only the
series the dashboards and alerts use. Storing the rest would cost disk for
data nobody queries.

## Dashboards

Provisioned as code, `allowUiUpdates: false`, so the repository stays the
source of truth and a dashboard cannot vanish without a commit.

| # | Dashboard | Answers |
|---|---|---|
| 1 | Infrastructure | Are the servers healthy? |
| 2 | Containers | Is anything crash-looping or near its memory limit? |
| 3 | PostgreSQL | Is the database healthy and are queries served from cache? |
| 4 | Odoo | Can users reach it, and how fast? |
| 5 | Backup | Are backups fresh, and has a restore actually been proven? |

## Alerts

26 rules. Severity means something specific:

| Severity | Means |
|---|---|
| `critical` | Someone is paged now |
| `warning` | Looked at during working hours |
| `info` | Visible on dashboards, never paged |

Every `for:` duration is deliberate. Alerting on an instantaneous spike trains
people to ignore alerts, which is worse than having none.

### Routing

**Order matters** — Alertmanager takes the first matching route:

1. `environment = dev` → `low-priority`. DEV is expected to break; it must
   never page anyone, whatever the severity.
2. `alertname =~ "Backup.*"` → `backup-alerts`. Urgent but not an outage:
   nobody should be woken, and equally it must not sit unread for days.
3. `severity = critical` and `environment = prod` → `critical-prod`, paging.
4. `severity = critical` elsewhere → `critical`.
5. `warning` → `warnings`. 6. `info` → `low-priority`.

This ordering was corrected after testing it. An earlier version put the
severity routes first, which sent DEV criticals to the paging receiver and
production backup alerts to the on-call channel:

```bash
amtool config routes test --config.file=alertmanager.yml \
  alertname=OdooDown severity=critical environment=dev
# must print: low-priority
```

Verify routing after any change to the route tree. It is the only way to know
where an alert actually lands.

### Inhibition

Four rules stop a single fault producing a wall of notifications:

- `ServerDown` suppresses everything else on that host
- `PostgreSQLDown` suppresses Odoo alerts in the same environment
- A firing `critical` suppresses its `warning` twin
- `DiskSpaceCritical` suppresses the disk warning and the prediction alert

### Notable rules

| Alert | Why it exists |
|---|---|
| `BackupStale` | A backup system that quietly stopped looks identical to one that works, until a restore |
| `BackupMissingEntirely` | "No data" and "everything is fine" look the same on a dashboard |
| `BackupRestoreNeverVerified` | Checksums prove bytes; only a restore proves a backup |
| `DiskWillFillIn24Hours` | Trend-based, so a runaway log is a ticket rather than an incident |
| `AlertmanagerUnreachable` | A dead Alertmanager silences everything while looking healthiest |
| `ContainerRestarting` | `docker ps` shows "running" each time you look at a crash loop |
| `PostgreSQLReplicationOrWALStalled` | Stalled archiving breaks PITR and fills `pg_wal` |

## Validating changes

Always, before deploying:

```bash
promtool check config monitoring/prometheus/prometheus.yml
promtool check rules  monitoring/alerts/odoo.yml
amtool check-config   monitoring/alertmanager/alertmanager.yml
amtool config routes test --config.file=... alertname=X severity=Y environment=Z
```

All four were run against this configuration: 26 rules valid, config valid,
6 receivers with 4 inhibition rules, and 10 of 10 routing cases landing where
intended.

## Reloading

```bash
curl -X POST http://127.0.0.1:9090/-/reload     # Prometheus
curl -X POST http://127.0.0.1:9093/-/reload     # Alertmanager
```

Grafana reloads provisioned dashboards every 30 seconds on its own.

## Current status

> The stack has never run. No Prometheus target has been scraped, no dashboard
> has rendered live data, and no alert has fired. Everything above is validated
> configuration, not observed behaviour. After the first deployment, check
> **Status → Targets** in Prometheus and confirm all four hosts report.
