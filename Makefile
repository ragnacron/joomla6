# ZIP is a host path to a built extension zip — anywhere, including another
# repository's build output. Building it is that repository's job, not this one's.
ZIP ?=

# Which extension type `make uninstall` lists when given no ID. Packages are the
# usual deliverable here; TYPE=component narrows it, TYPE= lists all 250-odd.
TYPE ?= package

DC := docker compose
EXEC := $(DC) exec -T joomla

.DEFAULT_GOAL := help
.PHONY: help setup up down destroy deploy uninstall shell cli logs db

help: ## Show this help
	@awk 'BEGIN {FS = ":.*## "} /^[a-z-]+:.*## / {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

setup: ## One-time per machine: .env, certificates, hosts line
	@test -f .env || cp .env.example .env
	@mkdir -p certs
	mkcert -install
	mkcert -cert-file certs/joomla.test.pem -key-file certs/joomla.test-key.pem \
		joomla.test "*.joomla.test"
	@echo
	@echo "Add this line to your hosts file, then run 'make up':"
	@echo "  127.0.0.1 joomla.test mail.joomla.test"

up: ## Start everything (first run installs Joomla, ~1 min)
	@test -f certs/joomla.test.pem || { echo "No certificate. Run 'make setup' first."; exit 1; }
	$(DC) up -d --build
	@printf "waiting for Joomla to install"
	@for i in $$(seq 1 60); do \
		$(EXEC) test -f configuration.php >/dev/null 2>&1 && break; \
		printf "."; sleep 2; \
	done; echo
	@$(EXEC) test -f configuration.php >/dev/null 2>&1 \
		|| { echo "Joomla did not install. Try 'make logs'."; exit 1; }
	@# Dev-only settings; idempotent, so re-running 'make up' is safe.
	@# HTTPS awareness is handled in Apache, see docker/proxy.conf.
	@$(EXEC) php cli/joomla.php config:set debug=1 error_reporting=maximum >/dev/null
	@echo
	@echo "  site   https://joomla.test"
	@echo "  admin  https://joomla.test/administrator"
	@echo "  mail   https://mail.joomla.test"

down: ## Stop, keep the database and site
	$(DC) down

destroy: ## Stop and delete all data — full reset
	$(DC) down -v

deploy: ## Install a built zip: make deploy ZIP=../dist/pkg_yours.zip
	@test -n "$(ZIP)" || { echo "usage: make deploy ZIP=path/to/extension.zip"; exit 1; }
	@test -f "$(ZIP)" || { echo "not a file: $(ZIP)"; exit 1; }
	@case "$(ZIP)" in *.zip) ;; *) echo "not a zip: $(ZIP)"; exit 1 ;; esac
	@$(DC) cp "$(ZIP)" joomla:/tmp/deploy.zip >/dev/null
	@$(EXEC) php cli/joomla.php extension:install --path=/tmp/deploy.zip

uninstall: ## Remove any extension: make uninstall ID=123 (no ID lists TYPE, default package)
	@test -n "$(ID)" || { $(EXEC) php cli/joomla.php extension:list $(if $(TYPE),--type=$(TYPE)); \
		echo; echo "Re-run with the id:  make uninstall ID=<id>"; \
		echo "Listing $(if $(TYPE),type '$(TYPE)',every type). Change it with TYPE=component, or TYPE= for all."; \
		exit 1; }
	@# -n skips the confirmation prompt; typing the id was the confirmation.
	@# Removing a package id also removes the extensions it installed — verified.
	@$(EXEC) php cli/joomla.php extension:remove $(ID) -n

shell: ## Bash inside the Joomla container
	$(DC) exec joomla bash

cli: ## Run a Joomla CLI command: make cli ARGS="config:get"
	$(DC) exec joomla php cli/joomla.php $(ARGS)

logs: ## Tail logs from all services
	$(DC) logs -f

db: ## MariaDB shell
	$(DC) exec db sh -c 'mariadb -u root -p"$$MARIADB_ROOT_PASSWORD" "$$MARIADB_DATABASE"'
