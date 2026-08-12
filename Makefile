SHELL := /bin/bash
# -p is not optional: without it the project name comes from the compose file's
# directory ("compose"), which then prefixes every volume name. Pinning it keeps
# volume names stable and predictable — they hold the node wallets.
PROJECT := hawtch
# Fall back to .env.example so `make validate` works before secrets exist —
# it is a syntax check, not a deployment. The run targets require a real .env
# via require-env, so the fallback can never silently start a misconfigured node.
ENV_FILE := $(shell test -f .env && echo .env || echo .env.example)
COMPOSE := docker compose -p $(PROJECT) --env-file $(ENV_FILE) \
	-f compose/docker-compose.observer.yml \
	-f compose/docker-compose.bees.generated.yml
NETWORK := hawtch

# Nodes enabled in fleet.yml, in declaration order. Read from a generated text
# file rather than by parsing YAML, so `make` needs nothing but a shell on the
# deploy host.
ENABLED := $(shell cat compose/enabled-nodes.generated.txt 2>/dev/null)

TEST_COMPOSE := docker compose -p hawtch-test -f compose/docker-compose.test.yml

.PHONY: help install generate network require-env preflight up up-observer up-bees up-staggered down stop ps logs validate addresses backup-keys reload-prometheus test-up test-check test-down test-logs

help:
	@echo "Setup"
	@echo "  install            npm install (js-yaml, for the generator)"
	@echo "  generate           render fleet.yml -> compose + prometheus config"
	@echo "  validate           generate, then check the merged compose file"
	@echo "  network            create the shared docker network"
	@echo "  preflight          assert no fleet port is already bound"
	@echo ""
	@echo "Run"
	@echo "  up-observer        prometheus, grafana, cadvisor, node-exporter"
	@echo "  up-bees            all enabled bee nodes at once"
	@echo "  up-staggered       bee nodes one at a time (preferred: see PLAN.md 4.1)"
	@echo "  up                 observer + staggered nodes"
	@echo "  down               stop and remove containers (volumes kept)"
	@echo "  stop               stop containers, leave them in place"
	@echo ""
	@echo "Test locally (against a running bee-factory cluster, no funds needed)"
	@echo "  test-up            observer stack pointed at bee-factory"
	@echo "  test-check         assert targets are up and metrics are landing"
	@echo "  test-logs          follow test stack logs"
	@echo "  test-down          stop and discard the test TSDB"
	@echo ""
	@echo "Operate"
	@echo "  ps                 container status"
	@echo "  logs               follow all logs"
	@echo "  addresses          print addresses to fund, and verify neighborhoods"
	@echo "  backup-keys        tar each node's keystore into ./backups/"
	@echo "  reload-prometheus  hot-reload config without dropping the TSDB"
	@echo ""
	@echo "Enabled nodes: $(ENABLED)"

install:
	npm install

generate:
	node tools/generate.mjs

validate: generate
	@# Shell env beats --env-file, so this satisfies the deliberate `:?` guard on
	@# GRAFANA_ADMIN_PASSWORD without weakening it for real deployments.
	@GRAFANA_ADMIN_PASSWORD=validate-only $(COMPOSE) config --quiet \
		&& echo "compose config OK ($(ENV_FILE))"

network:
	@docker network inspect $(NETWORK) >/dev/null 2>&1 \
		|| docker network create $(NETWORK)

require-env:
	@test -f .env || { \
		echo "no .env — copy .env.example and fill it in:"; \
		echo "  cp .env.example .env"; \
		exit 1; \
	}

up-observer: require-env generate network
	$(COMPOSE) up -d prometheus grafana cadvisor node-exporter

# Refuses to start if any fleet port is already bound — most likely a stray
# bee-factory cluster, or a previous run still up. Starting anyway would produce
# a partially-bound fleet whose read-only tools point at someone else's node.
preflight:
	@test -f compose/ports.generated.txt || { echo "run 'make generate' first"; exit 1; }
	@conflict=0; \
	while read -r name kind port; do \
		if nc -z 127.0.0.1 "$$port" >/dev/null 2>&1; then \
			echo "  ✗ port $$port ($$name/$$kind) is already in use"; conflict=1; \
		fi; \
	done < compose/ports.generated.txt; \
	if [ "$$conflict" = "1" ]; then \
		echo; \
		echo "Refusing to start. If that is a bee-factory cluster, stop it"; \
		echo "(cd ../bee-factory && node dist/cli.js stop) or raise port_base in fleet.yml."; \
		exit 1; \
	else \
		echo "  ✓ all fleet ports free"; \
	fi

up-bees: require-env generate network preflight
	$(COMPOSE) up -d $(ENABLED)

# Full nodes pull-syncing simultaneously against one disk bottleneck each other,
# which corrupts the pullsync measurement itself (PLAN.md 4.1). Starting them
# one at a time, waiting for each to begin syncing, keeps that contention out of
# the warmup data.
up-staggered: require-env generate network preflight
	@for n in $(ENABLED); do \
		echo "==> starting $$n"; \
		$(COMPOSE) up -d $$n; \
		echo "    waiting 5m before the next node (Ctrl-C to skip the wait)"; \
		sleep 300 || true; \
	done

up: up-observer up-staggered

down:
	$(COMPOSE) down

stop:
	$(COMPOSE) stop

ps:
	@$(COMPOSE) ps

logs:
	$(COMPOSE) logs -f --tail=100

addresses:
	@node tools/addresses.mjs

# The keystore is the wallet. Volumes survive `down`, but not `down -v`, not a
# disk failure, and not a mistaken `docker volume prune`.
backup-keys:
	@mkdir -p backups
	@for n in $(ENABLED); do \
		echo "==> $$n"; \
		docker run --rm \
			-v $(PROJECT)_$$n-data:/data:ro \
			-v "$$PWD/backups:/backup" \
			alpine tar czf /backup/$$n-keys.tar.gz -C /data keys 2>/dev/null \
			&& echo "    backups/$$n-keys.tar.gz" \
			|| echo "    no keys yet (has the node started?)"; \
	done
	@echo
	@echo "These are encrypted with BEE_PASSWORD. Back that up separately —"
	@echo "the archives are useless without it."

reload-prometheus: generate
	@curl -fsS -X POST http://127.0.0.1:9090/-/reload && echo "prometheus reloaded"

# ---- local test -------------------------------------------------------------
# Points the real observer stack at the bee-factory cluster on this host, so the
# scrape -> label -> rule -> dashboard path can be exercised without mainnet
# nodes or funding. Requires bee-factory to be running.

test-up:
	@docker ps --format '{{.Names}}' | grep -q bee-factory-bee-0 \
		|| { echo "bee-factory is not running — start it first"; exit 1; }
	$(TEST_COMPOSE) up -d
	@echo
	@echo "Prometheus  http://127.0.0.1:9090"
	@echo "Grafana     http://127.0.0.1:3000  (admin / \$$GRAFANA_ADMIN_PASSWORD, default 'admin')"
	@echo
	@echo "Give it ~30s to scrape, then: make test-check"

test-check:
	@bash tools/test-check.sh

test-logs:
	$(TEST_COMPOSE) logs -f --tail=100

test-down:
	$(TEST_COMPOSE) down -v
