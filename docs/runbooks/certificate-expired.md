# Runbook: certificate expiring or expired

**Alerts:** `CertificateExpiringSoon` (21 days), `CertificateExpiringCritical` (7 days)
**Severity:** SEV2 while valid, SEV1 once expired — every user gets a browser
security warning.

Certificate expiry is one of the few outages that is entirely preventable. If
these alerts are firing, renewal is already failing.

```bash
ssh deploy@<host>
cd /opt/odoo-platform
E=prod; DC="docker compose -f compose.yml -f compose.$E.yml"
```


## 1. What is actually being served?

```bash
echo | openssl s_client -connect <domain>:443 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates
```

Check what is served, not what is on disk — nginx may still be holding an old
certificate in memory.

## 2. Renew

```bash
certbot certificates
certbot renew --dry-run          # never skip the dry run
certbot renew
```

## 3. If renewal fails

| Error | Cause | Fix |
|---|---|---|
| `Timeout during connect` | Port 80 blocked | `ufw allow 80/tcp`; ACME needs it |
| `404 on /.well-known/acme-challenge/` | nginx not serving the challenge | Check the `^~ /.well-known/` block |
| `too many certificates` | Let's Encrypt rate limit | Wait; do not loop retries |
| `NXDOMAIN` | DNS changed | Fix DNS first |

The HTTP-01 challenge path must stay reachable over **plain HTTP**. That is
why the vhost serves `/.well-known/acme-challenge/` before redirecting
everything else to HTTPS. Removing that redirect exception is the usual cause
of a renewal that worked for a year and then stopped.

## 4. Install and reload

```bash
cp /etc/letsencrypt/live/<domain>/fullchain.pem config/nginx/tls/
cp /etc/letsencrypt/live/<domain>/privkey.pem   config/nginx/tls/
chmod 600 config/nginx/tls/privkey.pem

$DC exec proxy nginx -t
$DC exec proxy nginx -s reload
```

`nginx -s reload` is graceful — no dropped connections. A restart is not
needed and would briefly interrupt service.

## 5. Verify

```bash
echo | openssl s_client -connect <domain>:443 2>/dev/null \
  | openssl x509 -noout -dates

curl -sI https://<domain>/web/login | grep -i strict-transport-security
```

Prometheus should show `probe_ssl_earliest_cert_expiry` jump to roughly 90
days on the next scrape.

## 6. Prevention

- Let's Encrypt renews at 30 days; the 21-day alert means renewal is failing,
  not that the certificate is merely ageing
- Keep the certbot timer enabled: `systemctl status certbot.timer`
- Never remove the ACME location block from the nginx vhost
