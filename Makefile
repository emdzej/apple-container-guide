# Convenience targets. Everything here is a thin wrapper over scripts/ — read
# those for what actually happens.
SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

.PHONY: help
help: ## show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

# --- setup ------------------------------------------------------------------

.PHONY: install
install: ## install the toolchain via Homebrew and start services
	./scripts/bootstrap.sh

.PHONY: doctor
doctor: ## health check (read-only)
	./scripts/doctor.sh

.PHONY: dns
dns: ## make <name>.test resolve from this Mac (needs sudo)
	./scripts/setup-dns.sh test

# --- runtime ----------------------------------------------------------------

.PHONY: up
up: ## start container services + socktainer, point docker at Apple container
	container system start
	./scripts/socktainer-service.sh start
	docker context use socktainer

.PHONY: down
down: ## stop socktainer and the container services
	./scripts/socktainer-service.sh stop
	container system stop

.PHONY: apple desktop
apple: ## point docker at Apple container
	./scripts/switch-runtime.sh apple
desktop: ## point docker back at Docker Desktop
	./scripts/switch-runtime.sh desktop

.PHONY: which
which: ## what is docker talking to right now
	./scripts/switch-runtime.sh show

# --- migration --------------------------------------------------------------

.PHONY: audit
audit: ## list what Docker Desktop is holding
	-./scripts/migrate-images.sh --list
	-./scripts/migrate-volumes.sh --list

.PHONY: migrate
migrate: ## migrate all images and volumes from Docker Desktop
	./scripts/migrate-images.sh --all
	./scripts/migrate-volumes.sh --all

.PHONY: check-compose
check-compose: ## lint a compose file: make check-compose FILE=path/to/compose.yaml
	./scripts/compose-check.sh $(FILE)

# --- maintenance ------------------------------------------------------------

.PHONY: df clean clean-hard
df: ## disk usage
	container system df
clean: ## reclaim disk (safe set)
	./scripts/cleanup.sh
clean-hard: ## reclaim disk including all unused images and the builder cache
	./scripts/cleanup.sh --aggressive

# --- examples ---------------------------------------------------------------

.PHONY: smoke
smoke: ## run the end-to-end smoke test
	./examples/01-hello/run.sh

.PHONY: machine-demo
machine-demo: ## demo container machines (persistent Linux VMs), then clean up
	./examples/08-machine/run.sh

.PHONY: lint
lint: ## syntax-check every script in this repo
	@fail=0; \
	for f in scripts/*.sh scripts/lib/*.sh shell/*.sh examples/*/*.sh; do \
	  bash -n "$$f" || { echo "FAIL $$f"; fail=1; }; \
	done; \
	zsh -n shell/apple-container.sh || fail=1; \
	command -v shellcheck >/dev/null && shellcheck -S warning scripts/*.sh scripts/lib/*.sh examples/*/*.sh || true; \
	test $$fail -eq 0 && echo "all scripts parse cleanly"
