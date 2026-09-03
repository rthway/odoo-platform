# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning: [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Docker foundation: pinned Odoo 18 image, non-root, OCI labels, entrypoint
  that renders `odoo.conf` and waits for PostgreSQL
- Base Compose stack with DEV/QA/PROD overlays, an `internal` backend network
  and no published database port
- PostgreSQL 16 tuned for Odoo, WAL archiving, `pg_stat_statements`
- nginx as the sole ingress: TLS, security headers, rate limiting, database
  manager blocked
- Operational scripts: deploy, rollback, backup, restore, verify, migrate,
  prune, health check, secret generation
- Six GitHub Actions workflows with a protected `production` environment
- Security scanning: Gitleaks, CodeQL, Trivy, dependency review
- Observability: Prometheus with 26 alert rules, 5 Grafana dashboards,
  Loki, promtail, Alertmanager with verified routing
- Ansible: 5 roles covering hardening, Docker, deployment, monitoring agents
  and backup scheduling
- Documentation: 16 documents, 7 runbooks, 8 ADRs

### Known gaps

- Nothing deployed — no SSH access to `.223`, `.230`, `.231` or `.232`
- Off-site backup not configured, so 3-2-1 is not satisfied
- SonarQube not deployed
- CodeQL inactive until `addons/` contains Python
- Rollback, restore and PITR have not been rehearsed on real infrastructure
