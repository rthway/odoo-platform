# Contributing

## Before you start

Read [`docs/development.md`](docs/development.md) for local setup and
[`docs/git-workflow.md`](docs/git-workflow.md) for branching.

## Workflow

```bash
git switch develop && git pull
git switch -c feature/short-description
# work
./tests/run-all.sh
git push -u origin feature/short-description
gh pr create --base develop
```

## Standards

**Shell.** `#!/usr/bin/env bash` and `set -Eeuo pipefail`. Quote every
expansion. CI enforces both, plus shellcheck at warning level — an unquoted
variable in a deploy script becomes a production incident eventually.

**Comments.** Explain *why*, especially where the code looks odd. The
`NGINX_ENVSUBST_FILTER` line looks redundant until you know it stops nginx
blanking `$host`. That comment is the point.

**Commits.** Conventional Commits. The body explains why; the diff already
says what.

**Secrets.** Never. `*.example` files carry empty values, and
`tests/test-security.sh` asserts they stay empty.

## Adding a CI job

Add it to the workflow **and** to the `needs:` list of `ci-passed` or
`security-passed`. A job outside that list is not blocking, and the aggregate
check will report green while your new job fails.

## Changing monitoring

Validate before pushing — these tools catch real mistakes:

```bash
promtool check config monitoring/prometheus/prometheus.yml
promtool check rules  monitoring/alerts/odoo.yml
amtool check-config   monitoring/alertmanager/alertmanager.yml
amtool config routes test --config.file=... alertname=X severity=Y environment=Z
```

Route ordering in particular is not obvious: Alertmanager takes the first
match, and testing it is the only way to know where an alert lands.

## Changing anything production-facing

Say so in the PR, and describe the rollback. If it includes a schema
migration, state explicitly that an image rollback will not revert it.

## Review

At least one approval, CI and Security green. Reviewers should ask: what
happens when this fails, and how would we know?
