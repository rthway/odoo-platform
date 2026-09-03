# Ansible

Prepares the four servers to *run* deployments. It never deploys an
application image — that is `scripts/deploy.sh`, driven by GitHub Actions, so
image changes have a single audit trail rather than two.

## First run

```bash
cd infrastructure/ansible
ansible-galaxy collection install -r requirements.yml
cp inventory/hosts.example.ini inventory/hosts.ini   # then edit the SSH user
```

`inventory/hosts.ini` is gitignored: it names real hosts and real accounts.

## Usage

```bash
# Always dry-run first, especially against prod.
ansible-playbook site.yml --limit dev --check --diff

ansible-playbook site.yml --limit dev
ansible-playbook site.yml --limit qa
ansible-playbook site.yml --limit prod        # after --check
ansible-playbook site.yml --limit ops         # observability stack

# A single concern
ansible-playbook site.yml --tags firewall
ansible-playbook site.yml --tags backup
```

## Secrets

`postgres_password` and `odoo_admin_passwd` have **no defaults** — the run
fails without them, which is deliberate: a default password is a password
everybody already knows. Supply them from Ansible Vault:

```bash
ansible-vault create group_vars/prod/vault.yml
ansible-playbook site.yml --limit prod --ask-vault-pass
```

The rendered `.env` lands at `0600`, owned by the deploy user, and the play
asserts those permissions rather than assuming them.

## Roles

| Role | Does |
|---|---|
| `common` | SSH hardening, ufw, fail2ban, unattended security upgrades, sysctl, directories |
| `docker` | Docker Engine from Docker's own repository, daemon config, weekly image prune |
| `odoo_deploy` | Repository checkout, `.env` rendering, TLS, systemd unit |
| `monitoring_agent` | node_exporter, cAdvisor, postgres_exporter, promtail |
| `backup_schedule` | Daily backup, weekly verification restore, retention pruning |

## Firewall ordering

`roles/common` adds the SSH allow rule **before** setting the default-deny
policy. The reverse order locks everyone out of a remote host with no console,
which needs provider intervention to undo. Do not reorder those tasks.
