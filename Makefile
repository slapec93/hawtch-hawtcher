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
	-f compose/docker-compose.bees.generated.yml \
	-f compose/docker-compose.sidecars.generated.yml
NETWORK := hawtch

# Nodes enabled in fleet.yml, in declaration order. Read from a generated text
# file rather than by parsing YAML, so `make` needs nothing but a shell on the
# deploy host.
ENABLED := $(shell cat compose/enabled-nodes.generated.txt 2>/dev/null)

TEST_COMPOSE := docker compose -p hawtch-test -f compose/docker-compose.test.yml

.PHONY: help install generate check-generated check-env firewall firewall-grafana network volumes require-env preflight restore destroy up up-observer up-bees up-staggered up-sidecars down stop ps logs validate addresses backup-keys reload-prometheus test-up test-check test-down test-logs test-probes

help:
	@echo "Setup"
	@echo "  install            npm install (js-yaml, for the generator)"
	@echo "  generate           render fleet.yml -> compose + prometheus config"
	@echo "  validate           generate, then check the merged compose file"
	@echo "  check-generated    assert committed config matches fleet.yml (no Node needed)"
	@echo "  check-env          validate PUBLIC_IP, BEE_PASSWORD and the RPC chain id"
	@echo "  network            create the shared docker network"
	@echo "  firewall           open only the P2P ports, from fleet.yml"
	@echo "  firewall-grafana   open the Grafana port (opt-in; see .env)"
	@echo "  preflight          assert no fleet port is already bound"
	@echo ""
	@echo "Run"
	@echo "  up-observer        prometheus, grafana, cadvisor, node-exporter"
	@echo "  up-bees            all enabled bee nodes at once"
	@echo "  up-staggered       bee nodes one at a time (preferred: see PLAN.md 4.1)"
	@echo "  up-sidecars        active probes (needs funded nodes + postage)"
	@echo "  up                 observer + staggered nodes"
	@echo "  down               stop and remove containers (volumes kept)"
	@echo "  stop               stop containers, leave them in place"
	@echo ""
	@echo "Test locally (against a running bee-factory cluster, no funds needed)"
	@echo "  test-up            observer stack pointed at bee-factory"
	@echo "  test-check         assert targets are up and metrics are landing"
	@echo "  test-logs          follow test stack logs"
	@echo "  test-probes        run both probes against bee-factory (no real funds)"
	@echo "  test-down          stop and discard the test TSDB"
	@echo ""
	@echo "Operate"
	@echo "  ps                 container status"
	@echo "  logs               follow all logs"
	@echo "  addresses          print addresses to fund, and verify neighborhoods"
	@echo "  reload-prometheus  reload prometheus RULES/TARGETS (not prometheus.yml)"
	@echo ""
	@echo "Funded-wallet safety"
	@echo "  volumes            create the external node volumes (compose cannot delete these)"
	@echo "  backup-keys        keys + statestore + stamperstore -> ./backups/"
	@echo "  restore            restore identity archives back into the volumes"
	@echo "  destroy            DELETE node volumes (needs CONFIRM= and a backup)"
	@echo ""
	@echo "Enabled nodes: $(ENABLED)"

install:
	npm install

GENERATED := \
	compose/docker-compose.bees.generated.yml \
	compose/docker-compose.sidecars.generated.yml \
	compose/enabled-nodes.generated.txt \
	compose/ports.generated.txt \
	compose/volumes.generated.txt \
	compose/nodes.generated.txt \
	compose/fleet.sha256.generated.txt \
	prometheus/targets/bee.generated.json \
	prometheus/targets/sidecars.generated.json \
	prometheus/rules/reserve.generated.yml

# sha256sum on Linux, shasum on macOS.
SHA256 := $(shell command -v sha256sum >/dev/null && echo "sha256sum" || echo "shasum -a 256")

generate:
	node tools/generate.mjs

# Asserts the committed generated files exist and are not stale, WITHOUT running
# the generator. This is what keeps the deploy host free of a Node toolchain:
# generation happens on a workstation and the output is committed.
check-generated:
	@for f in $(GENERATED); do \
		test -f $$f || { \
			echo "missing $$f"; \
			echo "Run 'make generate' on a machine with Node, then commit the result."; \
			exit 1; }; \
	done
	@# Content comparison, NOT mtimes. git sets checkout timestamps in arbitrary
	@# order, so on a fresh clone fleet.yml frequently looks newer than the files
	@# generated from it — an mtime check fails there for no real reason.
	@want=$$(cat compose/fleet.sha256.generated.txt); \
	have=$$($(SHA256) fleet.yml | cut -d' ' -f1); \
	if [ "$$want" != "$$have" ]; then \
		echo "fleet.yml does not match the committed generated files."; \
		echo "  fleet.yml    $$have"; \
		echo "  generated by $$want"; \
		echo; \
		echo "Run 'make generate' on a machine with Node and commit the result,"; \
		echo "or the deployment will not match fleet.yml."; \
		exit 1; \
	fi
	@echo "  ✓ generated files present and match fleet.yml"

validate: generate
	@# Shell env beats --env-file, so this satisfies the deliberate `:?` guard on
	@# GRAFANA_ADMIN_PASSWORD without weakening it for real deployments.
	@GRAFANA_ADMIN_PASSWORD=validate-only FEED_PRIVATE_KEY=validate-only \
		$(COMPOSE) config --quiet \
		&& echo "compose config OK ($(ENV_FILE))"

network:
	@docker network inspect $(NETWORK) >/dev/null 2>&1 \
		|| docker network create $(NETWORK)

# Node volumes are declared `external` in the generated compose file, which means
# compose will neither create nor destroy them — `down -v` cannot touch a funded
# wallet. The trade-off is that they must be created here, up front.
volumes: check-generated
	@for v in $$(cat compose/volumes.generated.txt); do \
		docker volume inspect $$v >/dev/null 2>&1 \
			|| { docker volume create --label hawtch.keep=true $$v >/dev/null && echo "  created $$v"; }; \
	done
	@echo "  ✓ $$(wc -w < compose/volumes.generated.txt | tr -d ' ') node volume(s) present"

# Opens the P2P ports, and only those, from the generated port list — so the
# firewall cannot drift from fleet.yml. API ports are deliberately never opened:
# bee's API is unauthenticated and is bound to loopback.
firewall: check-generated
	@command -v ufw >/dev/null || { echo "ufw not installed (run deploy/bootstrap.sh)"; exit 1; }
	@while read -r name kind port; do \
		if [ "$$kind" = "p2p" ]; then \
			sudo ufw allow "$$port"/tcp comment "hawtch $$name p2p" >/dev/null \
				&& echo "  allowed $$port/tcp  ($$name p2p)"; \
		fi; \
	done < compose/ports.generated.txt
	@echo
	@echo "API ports left closed on purpose — bee's API is unauthenticated and"
	@echo "bound to 127.0.0.1. Reach Grafana/Prometheus over an SSH tunnel:"
	@echo "  ssh -L 3000:localhost:3000 -L 9090:localhost:9090 <host>"

# Opens the Grafana port, honouring GRAFANA_ALLOW_CIDR if set. Separate from
# `firewall` because exposing a dashboard is a deliberate decision, not part of
# routine setup.
firewall-grafana: require-env
	@command -v ufw >/dev/null || { echo "ufw not installed (run deploy/bootstrap.sh)"; exit 1; }
	@bind=$$(sed -n 's/^GRAFANA_BIND=//p' .env | tail -1); \
	port=$$(sed -n 's/^GRAFANA_PORT=//p' .env | tail -1); port=$${port:-3000}; \
	cidr=$$(sed -n 's/^GRAFANA_ALLOW_CIDR=//p' .env | tail -1); \
	if [ "$$bind" = "127.0.0.1" ] || [ -z "$$bind" ]; then \
		echo "GRAFANA_BIND is $${bind:-127.0.0.1} (loopback) — nothing to open."; \
		echo "Set GRAFANA_BIND=0.0.0.0 in .env and re-run 'make up-observer' first."; \
		exit 0; \
	fi; \
	if [ -n "$$cidr" ]; then \
		for c in $$(echo "$$cidr" | tr ',' ' '); do \
			sudo ufw allow from "$$c" to any port "$$port" proto tcp comment "hawtch grafana" >/dev/null \
				&& echo "  allowed $$port/tcp from $$c"; \
		done; \
		echo "  (every other source is denied by the default-deny policy)"; \
	else \
		sudo ufw allow "$$port"/tcp comment "hawtch grafana (any source)" >/dev/null \
			&& echo "  allowed $$port/tcp from ANY source"; \
		echo; \
		echo "  WARNING: open to the internet over plain HTTP. The admin password"; \
		echo "  crosses the network in cleartext. Set GRAFANA_ALLOW_CIDR, or put"; \
		echo "  Grafana behind TLS — see DEPLOY.md."; \
	fi

require-env:
	@test -f .env || { \
		echo "no .env — copy .env.example and fill it in:"; \
		echo "  cp .env.example .env"; \
		exit 1; \
	}

up-observer: require-env check-generated network volumes
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

# Validates the two .env values that produce cryptic, hard-to-diagnose failures.
# Both were hit for real during the first deployment:
#   - an Ethereum-mainnet RPC (chain 1) where bee needs Gnosis (chain 100)
#   - a loopback PUBLIC_IP, which bee rejects outright as a NAT address
check-env: require-env
	@rpc=$$(sed -n 's/^GNOSIS_RPC_ENDPOINT=//p' .env | tail -1); \
	ip=$$(sed -n 's/^PUBLIC_IP=//p' .env | tail -1); \
	pw=$$(sed -n 's/^BEE_PASSWORD=//p' .env | tail -1); \
	fail=0; \
	if [ -z "$$pw" ]; then echo "  ✗ BEE_PASSWORD is empty — bee will not start"; fail=1; \
	else echo "  ✓ BEE_PASSWORD set"; fi; \
	if [ -z "$$ip" ]; then \
		echo "  ✗ PUBLIC_IP is empty"; fail=1; \
	elif echo "$$ip" | grep -qE '^(127\.|::1$$|localhost$$)'; then \
		echo "  ✗ PUBLIC_IP=$$ip is loopback — bee rejects it: 'loopback address is not a valid address'"; fail=1; \
	elif echo "$$ip" | grep -qE '^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)'; then \
		echo "  ! PUBLIC_IP=$$ip is a private address — correct only if peers reach the host at it;"; \
		echo "    behind NAT, set the external address and forward the P2P ports"; \
	else \
		echo "  ✓ PUBLIC_IP=$$ip"; \
	fi; \
	if [ -z "$$rpc" ]; then \
		echo "  ✗ GNOSIS_RPC_ENDPOINT is empty — bee will not start"; fail=1; \
	elif ! echo "$$rpc" | grep -qE '^(http|https|ws|wss)://'; then \
		echo "  ✗ GNOSIS_RPC_ENDPOINT=$$rpc has no scheme."; \
		echo "    bee dials via go-ethereum's rpc.DialOptions, which picks the transport"; \
		echo "    from the scheme — with none it tries to open the value as an IPC socket"; \
		echo "    path and fails. Write it as http://host:port (curl tolerates the omission,"; \
		echo "    bee does not)."; fail=1; \
	else \
		chain=$$(curl -s -m 10 -X POST -H 'Content-Type: application/json' \
			--data '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' "$$rpc" \
			| grep -oE '"result":"0x[0-9a-fA-F]+"' | grep -oE '0x[0-9a-fA-F]+'); \
		if [ -z "$$chain" ]; then \
			echo "  ✗ RPC $$rpc did not answer eth_chainId"; fail=1; \
		elif [ "$$chain" != "0x64" ]; then \
			echo "  ✗ RPC is chain $$chain; Swarm needs Gnosis Chain (0x64 = 100)."; \
			echo "    An Ethereum-mainnet endpoint (0x1) is the usual mistake."; fail=1; \
		else \
			echo "  ✓ RPC is Gnosis Chain (0x64)"; \
		fi; \
	fi; \
	test "$$fail" = "0" || { echo; echo "Fix .env before starting nodes."; exit 1; }

up-bees: require-env check-env check-generated network volumes preflight
	$(COMPOSE) up -d $(ENABLED)

# Full nodes pull-syncing simultaneously against one disk bottleneck each other,
# which corrupts the pullsync measurement itself (PLAN.md 4.1). Starting them
# one at a time, waiting for each to begin syncing, keeps that contention out of
# the warmup data.
up-staggered: require-env check-env check-generated network volumes preflight
	@for n in $(ENABLED); do \
		echo "==> starting $$n"; \
		$(COMPOSE) up -d $$n; \
		echo "    waiting 5m before the next node (Ctrl-C to skip the wait)"; \
		sleep 300 || true; \
	done

# Probes need their paired nodes running and funded, and a postage batch. Start
# them after the fleet is up, not alongside it.
up-sidecars: require-env check-generated network
	$(COMPOSE) up -d --build $(shell sed -n 's/^  \(sidecar-[a-z]*\):$$/\1/p' compose/docker-compose.sidecars.generated.yml 2>/dev/null)

up: up-observer up-staggered

# Stops and removes containers. Volumes are external, so they survive this even
# if someone adds -v by hand. An identity snapshot is taken first regardless:
# the cheapest moment to have a backup is just before touching anything.
down: backup-keys
	$(COMPOSE) down
	@echo
	@echo "Containers removed. Node volumes kept (they are external):"
	@for v in $$(cat compose/volumes.generated.txt 2>/dev/null); do echo "  $$v"; done
	@echo
	@echo "WARNING: with no container referencing them, these volumes are now"
	@echo "'unused' and 'docker volume prune' WOULD delete them. Prefer 'make stop'"
	@echo "over 'make down' while the fleet is funded."

stop:
	$(COMPOSE) stop

ps:
	@$(COMPOSE) ps

logs:
	$(COMPOSE) logs -f --tail=100

addresses:
	@bash tools/addresses.sh

# Backs up node identity: the wallet AND the overlay nonce.
#
# keys/ alone is NOT enough. The Ethereum address comes from keys/swarm.key, but
# the overlay address is derived from that key plus a nonce stored in the
# statestore (`overlayV2_nonce`, see bee pkg/node/statestore.go). Restore keys/
# without the statestore and bee re-mines a different overlay.
#
# stamperstore holds postage stamp issuance state, which matters on the uploader
# nodes: losing it loses track of which stamp indices have been used.
#
# Volumes survive `down`, but not `down -v`, not a disk failure, and not a
# mistaken `docker volume prune`.
backup-keys:
	@mkdir -p backups
	@for n in $(ENABLED); do \
		echo "==> $$n"; \
		docker run --rm \
			-v $(PROJECT)_$$n-data:/data:ro \
			-v "$$PWD/backups:/backup" \
			alpine tar czf /backup/$$n-identity.tar.gz -C /data keys statestore stamperstore 2>/dev/null \
			&& echo "    backups/$$n-identity.tar.gz (keys + statestore + stamperstore)" \
			|| echo "    nothing to back up yet (has the node started?)"; \
	done
	@echo
	@echo "keys/ is encrypted with BEE_PASSWORD — back that up separately,"
	@echo "the archives are useless without it."
	@echo
	@echo "NOTE: taken while the nodes are running, so the leveldb copies may be"
	@echo "mid-write. For a guaranteed-consistent copy, 'make stop' first."

# Restores identity archives back into the volumes. This is what makes a lost
# volume survivable rather than terminal, so it is worth rehearsing BEFORE you
# need it — an untested backup is a guess.
#
# Refuses while a node's container is running: writing into a live leveldb
# corrupts it.
restore: volumes
	@for n in $(ENABLED); do \
		archive=backups/$$n-identity.tar.gz; \
		if [ ! -f $$archive ]; then echo "==> $$n: no $$archive, skipping"; continue; fi; \
		if docker ps --format '{{.Names}}' | grep -qx "hawtch-$$n"; then \
			echo "==> $$n: container is RUNNING — refusing (run 'make stop' first)"; \
			continue; \
		fi; \
		echo "==> $$n: restoring from $$archive"; \
		docker run --rm \
			-v hawtch_$$n-data:/data \
			-v "$$PWD/backups:/backup:ro" \
			alpine sh -c 'tar xzf /backup/'$$n'-identity.tar.gz -C /data && chown -R 999:999 /data' \
			&& echo "    restored (keys + statestore + stamperstore)"; \
	done
	@echo
	@echo "Verify with 'make up-bees && make addresses' — the Ethereum addresses"
	@echo "must match what you funded, and the overlays must match your pinned"
	@echo "neighborhoods."

# The only target that deletes funded wallets. Deliberately awkward: it demands
# an explicit confirmation string and refuses without a backup on disk, because
# `docker compose down -v` is far too easy to type by accident.
destroy:
	@test "$(CONFIRM)" = "delete-funded-volumes" || { \
		echo "This DELETES the node volumes, including funded wallets."; \
		echo "There is no undo unless you have a backup."; \
		echo; \
		echo "If you really mean it:"; \
		echo "  make destroy CONFIRM=delete-funded-volumes"; \
		exit 1; \
	}
	@for n in $(ENABLED); do \
		test -f backups/$$n-identity.tar.gz \
			|| { echo "refusing: no backups/$$n-identity.tar.gz — run 'make backup-keys' first"; exit 1; }; \
	done
	$(COMPOSE) down
	@for v in $$(cat compose/volumes.generated.txt); do docker volume rm $$v; done

reload-prometheus: check-generated
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

# Run both probes against the bee-factory cluster, on the host rather than in
# docker. Factory nodes are pre-funded on the local Anvil chain, so postage
# purchase works without spending anything real — which is the only way to
# exercise the postage path before pointing it at mainnet.
test-probes:
	@docker ps --format '{{.Names}}' | grep -q bee-factory-bee-0 \
		|| { echo "bee-factory is not running — start it first"; exit 1; }
	@test -d sidecars/node_modules || (cd sidecars && npm install)
	@cd sidecars && npm run build --silent
	@echo "starting probes against factory nodes 1633 (up) / 1635 (down)"
	@cd sidecars && \
		UPLOAD_BEE_URL=http://localhost:1633 DOWNLOAD_BEE_URL=http://localhost:1635 \
		POSTAGE_AUTO_BUY=true POSTAGE_DURATION_DAYS=2 POSTAGE_MIN_TTL_SECONDS=3600 \
		PAYLOAD_BYTES=10240 INTERVAL_SECONDS=15 TIMEOUT_SECONDS=45 \
		METRICS_PORT=9101 node dist/latency.js & \
	cd sidecars && \
		FEED_PRIVATE_KEY=$${FEED_PRIVATE_KEY:-$$(openssl rand -hex 32)} \
		UPLOAD_BEE_URL=http://localhost:1633 DOWNLOAD_BEE_URL=http://localhost:1635 \
		POSTAGE_AUTO_BUY=true POSTAGE_DURATION_DAYS=2 POSTAGE_MIN_TTL_SECONDS=3600 \
		INTERVAL_SECONDS=15 TIMEOUT_SECONDS=45 \
		METRICS_PORT=9102 node dist/beefeeder.js & \
	echo "latency -> :9101/metrics   beefeeder -> :9102/metrics   (Ctrl-C to stop)"; \
	wait

test-down:
	$(TEST_COMPOSE) down -v
