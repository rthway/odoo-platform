# 006. Prometheus, Grafana, Loki on a separate host

**Status:** Accepted
**Date:** 2026-09-03

## Context

Metrics and logs are needed across four servers. The critical question
is where the monitoring stack runs.

## Decision

Run Prometheus, Grafana, Loki and Alertmanager on **OPS .232**, separate
from every application host. Exporters run on the application hosts and are
reachable only from OPS. Add blackbox probing so Odoo is checked the way a
user reaches it.

## Consequences

Positive: an outage on the production host does not take the dashboards
and alerting with it — which is precisely when they are needed. Blackbox
probing catches expired certificates and proxy failures that container metrics
cannot see. Backup freshness is a metric, so a silently stopped backup alerts.

Negative: OPS is a single point of failure for observability. If it dies, the
platform keeps serving but blind. Accepted for four servers; the
`AlertmanagerUnreachable` rule at least makes a partly-dead stack visible.

Metrics bind to localhost and are reached over SSH tunnels, which is less
convenient than a public Grafana but avoids exposing an unauthenticated
monitoring surface.

## Alternatives considered

**Monitoring on each host** — no central view, and it dies with the host.

**A hosted service** — better availability, at the cost of sending operational
data to a third party and a recurring bill.

**Prometheus alone, no logs** — metrics say something is wrong; logs say
what. Both are needed.
