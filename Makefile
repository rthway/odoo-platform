# ===========================================================================
# Convenience targets. Everything here is a thin wrapper over the scripts,
# which remain the real interface - the pipeline calls those, not make.
# ===========================================================================

ENV ?= dev
DC  := docker compose -f compose.yml -f compose.$(ENV).yml

.DEFAULT_GOAL := help
.PHONY: help up down logs ps restart test lint check health smoke backup verify deploy rollback shell psql clean

help: ## Show this help
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) | \
	  awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "  ENV=$(ENV)  (override with: make up ENV=qa)"

up: ## Start the stack
	$(DC) up -d

down: ## Stop the stack, keeping volumes
	$(DC) down

logs: ## Follow Odoo logs
	$(DC) logs -f odoo

ps: ## Show container status
	$(DC) ps

restart: ## Restart Odoo only
	$(DC) restart odoo

health: ## Run health checks
	./scripts/healthcheck.sh -e $(ENV)

smoke: ## Run smoke tests against a running stack
	./tests/test-smoke.sh -e $(ENV)

test: ## Run all offline suites
	./tests/run-all.sh

check: ## Run offline suites plus runtime suites
	./tests/run-all.sh --with-runtime -e $(ENV)

lint: ## Lint only
	./tests/test-lint.sh

backup: ## Take a backup
	./scripts/backup.sh -e $(ENV) -l manual

verify: ## Verify the newest backup by restoring it
	./scripts/verify-backup.sh -s "$$(ls -1dt /var/backups/odoo/$(ENV)/*/ | head -1)" --restore

deploy: ## Deploy a tag:  make deploy TAG=2026.09.03-a1b2c3d
	@test -n "$(TAG)" || (echo "TAG is required, e.g. make deploy TAG=2026.09.03-a1b2c3d"; exit 1)
	./scripts/deploy.sh -e $(ENV) -t $(TAG)

rollback: ## Roll back to the previous tag
	./scripts/rollback.sh -e $(ENV) --reason "manual rollback via make"

shell: ## Open an Odoo shell
	$(DC) exec odoo odoo shell --config=/etc/odoo/odoo.conf --database=odoo_$(ENV)

psql: ## Open a psql session
	$(DC) exec db psql -U odoo_$(ENV) -d odoo_$(ENV)

# Deliberately not a `clean` that removes volumes. Deleting the database
# should require typing the command out in full and meaning it.
clean: ## Remove stopped containers and dangling images
	docker container prune -f
	docker image prune -f
