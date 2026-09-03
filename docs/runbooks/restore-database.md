# Runbook: restore the database

> **This destroys the target database.** Read
> [disaster-recovery.md](../disaster-recovery.md) first and be certain a
> restore is the right action. Fixing forward is usually better.

```bash
ssh deploy@<host>
cd /opt/odoo-platform
E=prod; DC="docker compose -f compose.yml -f compose.$E.yml"
```


## 1. Decide

| Situation | Restore? |
|---|---|
| Bad deployment, data intact | **No** — roll back the image |
| Migration produced wrong behaviour | Probably not — fix forward |
| Data corrupted or destroyed | Yes |
| Ransomware | Yes, from before the compromise |

A restore costs every transaction since the backup. That loss must be
explicitly accepted by someone authorised to accept it.

## 2. Choose a set

```bash
ls -1dt /var/backups/odoo/prod/*/ | head -10
cat <set>/manifest.json | jq '{timestamp, image_tag, database_size_bytes, encrypted}'
```

Prefer one carrying `verification.json` — that set has already been proven
restorable.

## 3. Verify BEFORE destroying anything

```bash
./scripts/verify-backup.sh -s <set> --restore
```

If this fails, **stop**. Restoring from a damaged set destroys the current
state and gains nothing. Try an older set.

## 4. Rehearse on QA

Whenever time allows:

```bash
./scripts/restore.sh -e qa -s <set>
./scripts/healthcheck.sh -e qa
./tests/test-integration.sh -e qa
```

This also measures how long the restore really takes, which is the RTO.

## 5. Restore production

```bash
./scripts/restore.sh -e prod -s <set> --i-understand-this-destroys-prod
```

The script will:

1. verify the backup again
2. **take a safety backup of the current state** — restoring the wrong set is
   a routine human error, and this is what makes it recoverable
3. require the database name to be typed, and fail closed with no TTY
4. stop Odoo, so nothing writes during the restore
5. terminate leftover connections, drop and recreate the database
6. `pg_restore --exit-on-error`
7. restore the filestore — without it every attachment 404s
8. restart and health-check

## 6. Verify

```bash
./scripts/healthcheck.sh -e prod
./tests/test-smoke.sh -e prod
./tests/test-integration.sh -e prod
```

Then check the data itself with someone who knows the business: the most
recent invoice, the latest orders, a document attachment opening correctly.

## 7. Match the image to the data

If the backup predates a migration, the running image must be the one that
matches that schema:

```bash
cat <set>/manifest.json | jq -r .image_tag
./scripts/deploy.sh -e prod -t <that tag>
```

Restoring a pre-migration database while running post-migration code
reproduces the original problem.

## 8. Afterwards

- Record exactly what data was lost, in the incident timeline
- Tell the people whose work is gone; they may be able to re-enter it
- Take a fresh backup immediately
- Review why the restore was needed
