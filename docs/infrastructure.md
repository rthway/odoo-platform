# Infrastructure

## Audit

Audited **2026-09-03** over SSH as `devops`, read-only. Nothing was installed,
started, stopped or changed.

| | DEV | QA | PROD | OPS |
|---|---|---|---|---|
| Public address | 157.10.100.223 | 157.10.100.230 | 157.10.100.231 | 157.10.100.232 |
| Internal address | 192.168.2.6 | 192.168.2.52 | 192.168.2.217 | 192.168.2.56 |
| Hostname | `VM-O-Dev` | `vm-o-qa` | `VM-O-Live` | `VM-O-Monitor` |
| OS | Ubuntu 24.04 LTS | **Ubuntu 18.04.6 LTS** | Ubuntu 24.04 LTS | Ubuntu 24.04 LTS |
| Kernel | 6.8.0-54 | 4.15 series | 6.8.0-54 | 6.8.0-54 |
| Python 3 | 3.12.3 | **3.6.9** | 3.12.3 | 3.12.3 |
| vCPU | 4 | 4 | 4 | **2** |
| RAM | 7.8 GB | 7.8 GB | 7.8 GB | **3.8 GB** |
| Disk free | 86 GB / 98 GB | 97 GB / 99 GB | 87 GB / 98 GB | **39 GB / 49 GB** |
| Disk device | `/dev/vda3` | `/dev/sda3` | `/dev/vda3` | `/dev/vda3` |
| Docker | not installed | not installed | not installed | not installed |
| PostgreSQL | not installed | not installed | not installed | not installed |
| nginx / Apache | none | none | none | none |
| Odoo | no trace | no trace | no trace | no trace |
| Listening | SSH only | SSH only | SSH only | SSH only |
| Reboot pending | no | **YES** | no | no |
| Clock | UTC, synced | UTC, synced | UTC, synced | UTC, synced |
| Failed units | none | none | none | none |

**All four are bare virtual machines.** There is no existing Odoo deployment,
no database and no data to preserve anywhere. That removes the migration risk
this project was originally scoped around: there is nothing to break.

### Access

`devops` exists on all four hosts with key-based SSH and membership of the
`sudo` group. **Sudo prompts for a password**, so Ansible needs
`--ask-become-pass` until `NOPASSWD` is granted.

`devops` is *not* in a `docker` group — Docker is not installed yet, and the
`docker` Ansible role adds the account when it installs the engine.

## Findings that changed the design

### 1. Networking — the firewall rule would not have matched

All four hosts sit on one `192.168.2.0/24` segment behind gateway
`192.168.2.1`; the `157.10.100.x` addresses are NAT.

`ip route get` on OPS shows it sources traffic from `192.168.2.56` **even when
dialling a 157.10.100.x address**:

```
157.10.100.231 via 192.168.2.1 dev ens3 src 192.168.2.56
```

The original ufw rule allowed the scrape from `157.10.100.232`, which the
target would never see. Prometheus would have been firewalled out of every
exporter, and the symptom — targets DOWN with no obvious cause — would have
been slow to diagnose.

Corrected: scrape targets, the promtail Loki endpoint and
`monitoring_server_ip` all use the internal addresses.

### 2. QA runs an end-of-life OS

QA is **Ubuntu 18.04.6**, out of standard support since April 2023, carrying
Python 3.6.9 and a reboot-pending flag. This matters for two reasons:

- **It breaks the premise of QA.** QA exists to be a faithful rehearsal of
  production. Production is 24.04 with kernel 6.8; QA is 18.04 with the 4.15
  series. Different kernel, different glibc, different Docker build. A release
  that passes there has not been rehearsed against production's runtime.
- **Tooling.** Modern `ansible-core` requires Python 3.7+ on managed nodes.
  3.6.9 is below that floor.

QA is also the only host on `/dev/sda3` rather than `/dev/vda3`, suggesting it
was built from a different image or at a different time.

### 3. OPS is undersized for its role

OPS carries Prometheus, Grafana, Loki, Alertmanager, blackbox, node-exporter,
cAdvisor **and every backup** on 2 vCPU, 3.8 GB RAM and 39 GB free.

The retention policy for production alone is 14 daily + 8 weekly + 12 monthly
= up to 34 backup sets. Production's disk is 98 GB. Once real data exists,
that policy cannot fit in 39 GB.

This is not urgent while the databases are empty, but it must be resolved
before production carries data. Options, in order of preference: attach a
separate backup volume; move the third copy off-site (which 3-2-1 requires
anyway); or shorten monthly retention.

## Ports

### Currently listening

Only SSH (22) on all four hosts, plus loopback-bound `systemd-resolved` on 53.
Nothing else is exposed today.

### Planned

| Port | Host | Service | Reachable from |
|---|---|---|---|
| 22 | all | SSH | admin networks |
| 443 | PROD | nginx (HTTPS) | users |
| 80 | PROD | nginx redirect + ACME | users |
| 8080, 8443 | DEV, QA | nginx | internal network |
| 9100 | app hosts | node_exporter | **192.168.2.56 only** |
| 9187 | app hosts | postgres_exporter | **192.168.2.56 only** |
| 8081 | app hosts | cAdvisor | **192.168.2.56 only** |
| 3000/9090/9093 | OPS | Grafana/Prometheus/Alertmanager | **localhost only** |
| 3100 | OPS | Loki | app hosts |

### Never exposed

| Port | Why |
|---|---|
| 5432 | PostgreSQL publishes no port; it sits on an `internal` network |
| 8069, 8072 | Odoo is reachable only through nginx |
| 2375/2376 | the Docker daemon is never exposed remotely |

## Reaching the monitoring stack

Grafana, Prometheus and Alertmanager bind to `127.0.0.1`. None has
authentication strong enough to face the internet.

```bash
ssh -L 3000:127.0.0.1:3000 \
    -L 9090:127.0.0.1:9090 \
    -L 9093:127.0.0.1:9093 \
    devops@157.10.100.232
```

Then <http://localhost:3000>.

## Firewall

Nothing is configured yet — `ufw` is installed but its status needs root.
`roles/common` applies default-deny inbound with allow outbound.

**The SSH allow rule is added before the default-deny policy is set.** The
reverse order locks everyone out of a remote host with no console, which needs
provider intervention to undo. Do not reorder those tasks.

## Capacity

Measured, against what the workload needs:

| | DEV | QA | PROD | OPS |
|---|---|---|---|---|
| vCPU | 4 ✅ | 4 ✅ | 4 ✅ | 2 ⚠ |
| RAM | 7.8 GB ✅ | 7.8 GB ✅ | 7.8 GB ✅ | 3.8 GB ⚠ |
| Disk | 86 GB ✅ | 97 GB ✅ | 87 GB ✅ | 39 GB ⚠ |

With 4 vCPU, production's `ODOO_WORKERS` should be **9** by the
`(2 × vCPU) + 1` rule. `.env.prod.example` currently says 5, which is
conservative and safe on 7.8 GB of RAM — 9 workers at roughly 1 GB each would
not leave room for PostgreSQL's `shared_buffers`. **Keep 5** and revisit once
real load is measured.

PostgreSQL `shared_buffers` at 25% of 7.8 GB is ~2 GB, which is what
`config/postgres/postgresql.conf` already sets.

## DNS and TLS

No domain is configured, and no host has a public DNS name. The intended
layout:

| Name | Points to |
|---|---|
| `odoo.example.com` | PROD .231 |
| `odoo-qa.example.com` | QA .230 |
| `odoo-dev.example.com` | DEV .223 |
| `grafana.example.com` | OPS .232 (behind VPN) |

Until real names exist, DEV and QA use self-signed certificates from
`scripts/gen-local-tls.sh`. **Production refuses to configure without a real
certificate** — that assertion in `roles/odoo_deploy` is deliberate.
