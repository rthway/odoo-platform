# Logging

## Design

```
Odoo, PostgreSQL, nginx   ->  Docker json-file  ->  promtail  ->  Loki  ->  Grafana
Host syslog, auth.log     ->  promtail          ->  Loki
```

Everything logs to stdout. Nothing writes a log file inside a container — a
container filesystem is disposable, and a log written there is lost exactly
when it is needed.

Every service uses bounded json-file logging (20 MB × 5). Without that, a
chatty Odoo fills the disk and takes the host down, which is a far more common
outage than any application bug.

## Label cardinality

**Labels are indexed; log lines are not.** This is the single decision that
determines whether Loki stays usable.

| Label | Values | Kept |
|---|---|---|
| `environment` | 4 | Yes |
| `host` | 4 | Yes |
| `service` | ~4 | Yes |
| `level` | ~5 | Yes |
| `status` (nginx) | ~dozens | Yes |
| Request ID | unbounded | **No** |
| User ID | unbounded | **No** |
| Database name | low, but redundant | No |

A label per request would multiply series without making any query more
useful. Search the line content instead — that is what Loki is built for.

## Parsing

**Odoo.** The format is
`2026-09-03 10:15:32,123 7 INFO db module: message`. Tracebacks arrive as many
lines, so promtail collapses them into the entry they belong to. Without that,
every incident review is a jigsaw puzzle of 40 fragments.

**PostgreSQL.** Parsed for level, using the `log_line_prefix` set in
`postgresql.conf`.

**nginx.** Emitted as JSON directly, so promtail parses fields rather than
regexing a blob at query time. Slow requests are also converted into a
counter metric.

**syslog.** Authentication failures become an `ssh_auth_failures_total`
counter, so a brute-force attempt can alert rather than merely be recorded.

## Useful queries

```logql
# Errors across everything, last hour
{environment="prod"} |= "ERROR"

# Odoo tracebacks only
{service="odoo"} |~ "(?i)(traceback|exception)"

# HTTP 5xx from nginx
{service="proxy"} | json | status >= 500

# Slowest requests
{service="proxy"} | json | request_time > 5

# Failed logins
{service="odoo"} |~ "(?i)(authentication failed|login failed)"

# Database errors
{service="db"} |= "ERROR"

# Deadlocks
{service="db"} |~ "deadlock detected"

# What happened around a deployment
{environment="prod"} |~ "(?i)(starting odoo|shutting down|entrypoint)"

# Error rate, as a metric
sum by (service) (rate({environment="prod"} |= "ERROR" [5m]))
```

## Retention

30 days (`retention_period: 720h`) — long enough for post-incident review,
short enough that a modest OPS disk is not the constraint. The compactor
enforces it.

Anything needed beyond 30 days should be exported deliberately rather than
extending retention for everything.

## During an incident

1. Narrow the window in Grafana to just before the first symptom.
2. Start with `{environment="prod"} |= "ERROR"` and widen from there.
3. Correlate against the Odoo dashboard — a spike in response time and a burst
   of errors at the same moment usually share a cause.
4. Check `{service="db"}` before concluding the fault is in the application;
   Odoo failures are frequently database failures wearing a disguise.
5. Check the deployment history: `tail .deploy-state/history.log`. The most
   common cause of "it broke at 14:03" is that something was deployed at 14:02.

## Troubleshooting the pipeline

```bash
# Is promtail running and shipping?
docker logs promtail --tail 50

# Is Loki accepting writes?
curl -s http://127.0.0.1:3100/ready
curl -s http://127.0.0.1:3100/metrics | grep loki_distributor_lines_received_total

# Which labels does Loki actually know about?
curl -s http://127.0.0.1:3100/loki/api/v1/labels | jq
```

Common causes of missing logs:

| Symptom | Likely cause |
|---|---|
| No logs from one host | promtail cannot reach `.232:3100`; check ufw |
| No logs from one container | It has no compose service label, so promtail drops it |
| Logs stop after a restart | The positions file is not on a volume |
| Old logs rejected | `reject_old_samples_max_age` is 168h |

## Current status

> Loki has never ingested a log line. The configuration is validated but the
> pipeline is unproven. After the first deployment, confirm with
> `curl /loki/api/v1/labels` that `service`, `environment` and `host` all
> appear.
