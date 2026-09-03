# Security

## Controls

| Layer | Control | Where |
|---|---|---|
| Source | Gitleaks over full history | `security.yml` |
| Source | CodeQL `security-and-quality` | `security.yml` |
| Dependencies | Trivy fs, dependency review | `security.yml` |
| Image | Trivy **before push** | `build.yml` |
| Image | Non-root user, asserted | Dockerfile, CI |
| Runtime | `no-new-privileges`, read-only nginx | `compose.prod.yml` |
| Network | `internal` backend network | `compose.yml` |
| Network | ufw default-deny | `roles/common` |
| Transport | TLS 1.2/1.3, HSTS | nginx |
| Application | `list_db=False`, `dbfilter` | `odoo.conf.tmpl` |
| Application | nginx blocks `/web/database/*` | nginx vhost |
| Access | SSH keys only, fail2ban | `roles/common` |
| Secrets | GitHub Environment Secrets → `.env` at 0600 | Ansible |
| Backups | age encryption | `backup.sh` |

## Defence in depth: the database manager

Odoo's database manager can create, drop and restore databases over HTTP. It
is blocked three independent ways:

1. `list_db = False` in `odoo.conf`
2. nginx returns 404 for `/web/database/(create|drop|restore|manager|backup)`
3. the container entrypoint **refuses to start** with `list_db=True` when
   `ENVIRONMENT` is not `dev`

Any one would do. All three means a single misconfiguration is not an
exposure. The QA and PROD deployment workflows also probe the endpoint from
outside after every deployment and fail if it returns 200.

## Vulnerability policy

| Severity | Fix available | Action |
|---|---|---|
| CRITICAL | Yes | **Block.** Fix before merge |
| CRITICAL | No | Block; document and escalate |
| HIGH | Yes | **Block** |
| HIGH | No | Report to the Security tab; weekly review |
| MEDIUM | Any | Report only |
| LOW | Any | Report only |

`ignore-unfixed: true` on the gating scans is deliberate. An unfixable CVE in
the upstream Odoo base image cannot be resolved by failing the build; blocking
on it only trains people to bypass the gate. Those are tracked in the Security
tab and reviewed weekly, and the base image is rebuilt on a schedule so fixes
are picked up when they land.

## Secrets

### Where they live

```
GitHub Environment Secrets  (dev / qa / production, isolated)
        │  Ansible reads them
        ▼
/opt/odoo-platform/.env     (0600, owned by the deploy user)
        │  compose reads it
        ▼
container environment
```

Never in Git, never in a Dockerfile, never in a compose file, never in a log.
`no_log: true` is set on the Ansible tasks that touch them.

The `odoo_deploy` role **asserts** the rendered `.env` is `0600` rather than
assuming the template applied it.

### What is committed

Only `*.example` files, with empty values. `tests/test-security.sh` asserts
those values stay empty, and that assertion is negative-tested — a planted
password causes a failure.

### Generating

```bash
./scripts/gen-secrets.sh prod
```

Writes to stdout, never to a file in the repository, so a generated secret
cannot be swept up by `git add -A`.

### Rotation

Rotate on a schedule, and immediately after any suspected exposure — including
a secret pasted into a chat, a ticket, or shell history.

```bash
# 1. New value
./scripts/gen-secrets.sh prod | grep POSTGRES_PASSWORD

# 2. Update the environment secret
gh secret set POSTGRES_PASSWORD --env production

# 3. Re-render .env on the host
cd infrastructure/ansible
ansible-playbook site.yml --limit prod --tags config

# 4. Change it in PostgreSQL itself
docker compose -f compose.yml -f compose.prod.yml exec -T db \
  psql -U odoo_prod -c "ALTER USER odoo_prod WITH PASSWORD '<new>';"

# 5. Restart so Odoo picks it up, then verify
docker compose -f compose.yml -f compose.prod.yml up -d
./scripts/healthcheck.sh -e prod
```

| Secret | Rotate |
|---|---|
| PostgreSQL password | Annually, or on exposure |
| Odoo master password | Annually, or on exposure |
| SSH deployment keys | Annually, or when someone leaves |
| Docker Hub token | Annually |
| Grafana admin | Annually |
| age backup key | Rarely — old backups need the old key |

Rotating the age key makes existing backups unreadable without the old one.
Keep retired keys until every backup encrypted with them has aged out.

## If a secret is leaked

1. **Rotate first.** Do not start with the git history.
2. Assume it is compromised the moment it was exposed, not when it was noticed.
3. Removing it from history does **not** un-leak it — clones and forks persist.
4. Review Loki and PostgreSQL logs for use of the credential.
5. Only then consider history rewriting, and only with agreement, since it
   breaks every existing clone.

## Accepted risks

Recorded deliberately rather than left implicit:

| Risk | Why it is accepted | Mitigation |
|---|---|---|
| **Docker-published ports bypass ufw** | Docker inserts its own iptables rules ahead of ufw's INPUT chain, so a published port is reachable even when ufw appears to deny it. This affects Loki's 3100 on OPS, the only monitoring port not bound to loopback. | Loki binds to the host's INTERNAL address only, which is a private RFC1918 network behind NAT with no port forward. The ufw rule is kept because it is correct if traffic ever arrives via the host stack, but it is not the control doing the work. Proper filtering would need rules in the `DOCKER-USER` chain - recorded as an improvement, not claimed as done. |
| The deploy user is in the `docker` group, which is root-equivalent | Deployments would otherwise need passwordless sudo, which is no better | Key-only SSH, fail2ban, dedicated account |
| promtail mounts the Docker socket read-only | Required for container log discovery | Read-only, and the container is not exposed |
| cAdvisor runs privileged | Required to read cgroup and device statistics | Reachable only from OPS via ufw |
| No CSP header | Odoo's web client relies on inline scripts and eval; a naive CSP breaks the backend outright | Other headers set; a report-only rollout is the correct path |
| Grafana has no SSO | Small team, localhost-bound | Strong admin password, SSH tunnel only |

## Outstanding

- [x] Servers audited, and `roles/common` **applied and verified on DEV and
      OPS**: ufw active with the intended rules, fail2ban and chrony running,
      SSH hardened. QA and PROD not yet provisioned.
- [ ] No real TLS certificates; DEV and QA use self-signed
- [ ] SonarQube not deployed
- [ ] CodeQL will not run until `addons/` contains Python
- [ ] No VPN; administrative access is plain SSH from anywhere the firewall permits
- [ ] Off-site backups not configured
- [ ] CSP not implemented

## Reporting

Report suspected vulnerabilities privately to the repository owner. Do not
open a public issue.
