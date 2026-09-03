# CI/CD

## Pipelines

| Workflow | Trigger | Blocking |
|---|---|---|
| `ci.yml` | PR, push to main/develop | Yes — `CI passed` |
| `security.yml` | PR, push, weekly cron | Yes — `Security passed` |
| `build.yml` | Push to develop/main, tags | Produces the artifact |
| `deploy-dev.yml` | After a successful Build on develop | — |
| `deploy-qa.yml` | Manual | — |
| `deploy-prod.yml` | Manual + **approval** | — |

## CI jobs

| Job | Checks |
|---|---|
| `lint` | shellcheck, yamllint, hadolint, actionlint, executable bits |
| `config` | All three overlays resolve; **environment isolation assertions** |
| `ansible` | `--syntax-check` and ansible-lint (only possible on Linux) |
| `test` | `tests/run-all.sh` |
| `integration` | Builds the image, runs real Odoo + PostgreSQL, smoke tests, **backup/restore round trip** |

The isolation assertions are the important ones. They fail the build if:

- two environments share a database name or project name
- QA or PROD has `list_db=True`
- QA or PROD bind-mounts anything from the host
- any environment publishes a database port
- the three environments resolve to different image references

These are properties a reviewer cannot reliably eyeball on a large diff, so
they are asserted rather than reviewed.

## Security gates

```mermaid
flowchart LR
    PR[Pull request] --> GL[Gitleaks<br/>full history]
    PR --> CQ[CodeQL]
    PR --> TR[Trivy fs]
    PR --> DR[Dependency review]
    GL & CQ & TR --> SP{Security passed}
    SP -->|fail| BLOCK[Merge blocked]
    SP -->|pass| OK[Mergeable]

    style BLOCK fill:#7f1d1d,color:#fff
```

Gitleaks runs with `fetch-depth: 0`. A secret committed and removed in a later
commit is **still in the history and still compromised**; a shallow clone
would miss exactly that case.

CodeQL is guarded by a language-detection job: it errors out when a language
has no sources, and `addons/` is empty until the first custom module lands.
The aggregate job accepts `skipped` for CodeQL alone.

## Build gates

```
build (local, not pushed)
  -> verify the OCI revision label equals the commit SHA
  -> verify the image does not run as root
  -> Trivy SARIF into the Security tab
  -> Trivy policy gate: fixable CRITICAL/HIGH fails the build
  -> SBOM (CycloneDX)
  -> push to Docker Hub
  -> attest build provenance
```

The image is built locally and pushed only after every gate passes. An image
that fails its scan never exists in the registry, so nobody can deploy it by
hand later.

## Deployment security

The Docker daemon is **never** exposed to GitHub Actions. The runner opens an
SSH session and the server pulls its own image:

```
runner --ssh--> host --> ./scripts/deploy.sh --> docker pull
```

`StrictHostKeyChecking=yes` with pinned `SSH_KNOWN_HOSTS`. Without it, a
deployment could be silently redirected to another host.

## Secrets and variables

Per environment, under **Settings → Environments**:

| Environment | Secrets | Reviewers |
|---|---|---|
| `dev` | `SSH_HOST`, `SSH_USER`, `SSH_PRIVATE_KEY`, `SSH_KNOWN_HOSTS` | None |
| `qa` | the same four, QA values | None |
| `production` | the same four, PROD values | **Required** |

Repository level: `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN`. The token must
be a Docker Hub **access token** scoped read/write, never the account
password, so it can be revoked without changing the account.

Variables: `DOCKERHUB_NAMESPACE`, `APP_DIR`, `DEV_URL`, `QA_URL`, `PROD_URL`.

Production secrets live in the `production` environment, so a workflow run
targeting `dev` cannot read them.

## Setting it up

```bash
gh secret set DOCKERHUB_USERNAME
gh secret set DOCKERHUB_TOKEN

for env in dev qa production; do
  gh api -X PUT "repos/:owner/:repo/environments/$env"
  gh secret set SSH_HOST        --env "$env"
  gh secret set SSH_USER        --env "$env"
  gh secret set SSH_PRIVATE_KEY --env "$env"
  gh secret set SSH_KNOWN_HOSTS --env "$env"
done
```

Required reviewers on `production` are set in the web UI, or via the API with
a `reviewers` payload.

Collect the value for `SSH_KNOWN_HOSTS` with:

```bash
ssh-keyscan -t ed25519 157.10.100.231
```

## Deployment keys

Generate a dedicated key per environment. Never reuse a personal key, and
never commit a private key.

```bash
ssh-keygen -t ed25519 -C "github-actions-prod" -f ./deploy_prod -N ""

# public half onto the server
ssh-copy-id -i ./deploy_prod.pub deploy@157.10.100.231

# private half into the environment secret, then destroy the local copy
gh secret set SSH_PRIVATE_KEY --env production < ./deploy_prod
shred -u ./deploy_prod ./deploy_prod.pub
```

## SonarQube

Not yet deployed. When it is, add a `sonarqube` job to `ci.yml` **and add it
to the `ci-passed` needs list** — otherwise the quality gate is advisory and
blocks nothing, which is the usual way a quality gate ends up decorative.
