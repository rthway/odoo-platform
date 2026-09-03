# Runbook: rebuild the QA VM on a supported OS

**Severity:** SEV3 — QA serves nothing, so there is no outage. It blocks the
release path, which is worse than it looks: `deploy-prod.yml` takes an
`image_tag` "already validated in QA", and nothing can be validated in QA.

**Owner:** whoever owns the hypervisor. Nothing in this repository can fix it;
Ansible cannot reach far enough into the host to replace its own interpreter's
operating system.

## Why

QA (`157.10.100.230`, `vm-o-qa`) runs **Ubuntu 18.04.6 LTS** with **Python
3.6.9**. `ansible-core` 2.21 requires **Python 3.9 or newer on the managed
node** — `module_utils/basic.py` refuses to run below it — so every play dies
in `Gathering Facts`:

```
SyntaxError: future feature annotations is not defined
```

`site.yml` now reports this in pre-flight, over `raw`, naming the host and the
version it found. That makes the failure legible; it does not make it go away.

18.04 left standard support in **April 2023**. Beyond Ansible:

- Docker's apt repository has no `bionic` packages, so the `docker` role
  cannot install an engine there.
- The kernel is the 4.15 series against production's 6.8 — different kernel,
  different glibc, different container runtime. A release that passes on that
  host has not been rehearsed against production.
- No security updates.

QA is also the only host on `/dev/sda3` rather than `/dev/vda3`, which suggests
it was built from a different image or at a different time to the other three.

**Do not work around this with an interpreter override.** Installing a newer
Python from a PPA and pointing `ansible_python_interpreter` at it gets Ansible
running and leaves every objection above standing. QA would still not be a
rehearsal of production, which is the only reason QA exists.

## What the replacement needs

Match production (`157.10.100.231`, `VM-O-Live`) rather than inventing a spec:

| | Required | Production has |
|---|---|---|
| OS | Ubuntu 24.04 LTS | Ubuntu 24.04 LTS |
| Python 3 | 3.9+ (24.04 ships 3.12) | 3.12.3 |
| vCPU | 4 | 4 |
| RAM | 7.8 GB | 7.8 GB |
| Disk | 98 GB+ | 98 GB |
| Internal address | `192.168.2.52` | `192.168.2.217` |
| Routable address | `157.10.100.230` | `157.10.100.231` |

Both addresses must be preserved. `192.168.2.52` is what the OPS firewall
rules and Prometheus scrape targets name — hosts source traffic from the
internal address even when dialling a `157.10.100.x` one, which is
[finding 1](../infrastructure.md#1-networking--the-firewall-rule-would-not-have-matched).

Nothing needs to be preserved from the current VM. It has no Docker, no
PostgreSQL, no Odoo and no data — confirmed by the
[initial audit](../infrastructure.md#initial-audit). Rebuild, do not migrate.

## Before handing it back

```bash
ssh devops@157.10.100.230 'hostname; . /etc/os-release; echo "$PRETTY_NAME"; python3 -V; nproc; free -g | head -2; df -h /'
```

Required:

- `devops` exists, in the `sudo` group, with the deploy public key in
  `~/.ssh/authorized_keys`
- `sudo -n true` succeeds (NOPASSWD), as on the other three hosts
- `python3 -V` reports 3.9 or newer
- No pending reboot (`/var/run/reboot-required` absent) — the current VM has
  one outstanding

## Then

The host key changes with the rebuild, so the pinned `known_hosts` has to be
refreshed before Ansible will connect:

```bash
ssh-keygen -R 157.10.100.230
ssh-keyscan -H 157.10.100.230
```

Update the `SSH_KNOWN_HOSTS` repository secret with the new line — the
Provision and Deploy workflows write that secret verbatim and run with
`ANSIBLE_HOST_KEY_CHECKING=True`, so a stale entry fails the run.

1. **Provision, dry run.** Actions → Provision → environment `qa`, **Apply**
   unticked. Pre-flight should now pass the interpreter check and report
   `Ubuntu 24.04`.
2. **Provision, apply.** Same, **Apply** ticked. Expect the post-run
   verification play to assert Docker usable by `devops`, `.env` at `0600`,
   ufw active and the backup cron entry present.
3. **Deploy.** Actions → Deploy QA with an `image_tag` already validated in
   DEV.
4. **Confirm from outside the fleet**, not from the host:

   ```bash
   curl -kI https://157.10.100.230/
   ```

   Expect a redirect from Odoo, and a certificate warning — QA has no DNS name
   so the certificate is self-signed.
5. **Check QA appears in monitoring.** Its exporters should come up as
   Prometheus targets, reachable from `192.168.2.56` only. Targets `DOWN` with
   the host otherwise healthy points at the ufw rule and the internal address —
   see [troubleshooting.md](../troubleshooting.md#monitoring-gaps).

## Afterwards

Update the fleet tables in [infrastructure.md](../infrastructure.md) and the
"Live?" column in the README. Delete the
[end-of-life OS finding](../infrastructure.md#2-qa-runs-an-end-of-life-os)
once it is no longer true, and keep the pre-flight interpreter assertion — it
costs one `raw` call per host and is the reason this was a one-line diagnosis
the second time.
