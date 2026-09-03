## What this changes

<!-- One or two sentences. The diff says what; say why. -->

## Why

<!-- The problem being solved. Link the issue if there is one. -->

## Type

- [ ] feat — new capability
- [ ] fix — bug fix
- [ ] docs
- [ ] ci — pipeline
- [ ] infra — Ansible, servers, networking
- [ ] security
- [ ] refactor / test / chore

## Testing

<!-- What you actually ran, and what it said. Not what you intend to run. -->

- [ ] `./tests/run-all.sh` passes
- [ ] Tested against a running stack (`--with-runtime`)
- [ ] Documentation updated

## Risk

- [ ] Changes production configuration
- [ ] Involves a database migration
- [ ] Changes firewall, TLS or secrets handling
- [ ] Changes backup or restore behaviour

<!-- If any box above is ticked, describe the rollback plan. -->

## Rollback

<!-- How to undo this if it goes wrong in production.
     If it includes a schema migration, say so explicitly: an image
     rollback will NOT revert the database. -->

## Checklist

- [ ] No secrets in the diff (Gitleaks scans full history and will find them)
- [ ] New scripts are executable and use `set -Eeuo pipefail`
- [ ] Commit messages follow Conventional Commits
