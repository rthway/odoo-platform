# Architecture decision records

Decisions with lasting consequences, and the reasoning behind them — including
the options rejected and what would make us revisit.

| # | Decision | Status |
|---|---|---|
| [001](001-container-strategy.md) | Docker Compose rather than Kubernetes | Accepted |
| [002](002-version-pinning.md) | Pin every image to a dated tag | Accepted |
| [003](003-database-selection.md) | PostgreSQL in a container, one per environment | Accepted |
| [004](004-backup-strategy.md) | pg_dump with verified restores, not pgBackRest | Accepted |
| [005](005-reverse-proxy.md) | nginx as the only ingress | Accepted |
| [006](006-observability.md) | Prometheus, Grafana, Loki on a separate host | Accepted |
| [007](007-tls-and-http-security.md) | TLS 1.2+, HSTS, and no CSP for now | Accepted |
| [008](008-no-terraform.md) | Ansible only, no Terraform | Accepted |

An ADR is not changed once accepted. If a decision is reversed, a new record
supersedes it, so the history of *why* stays intact.
