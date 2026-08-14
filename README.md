# <img src="assets/icon.png" width="30" align="top" alt=""> Hawtch-Hawtcher, the Bee watcher

Monitoring suite for **Swarm mainnet**, driven by a purpose-built Bee probe fleet.

See [PLAN.md](PLAN.md) for the design and, importantly, [§4](PLAN.md#4-what-single-host-costs-us-read-this-before-trusting-v0-numbers) — the measurement limits v0's single-host setup imposes.

This repo currently contains the **infra/ops layer**. Sidecars (phase 4) are not built yet.

---

## How it fits together

`fleet.yml` is the only file you edit. `make generate` renders it into:

| Generated file | Purpose |
|---|---|
| `compose/docker-compose.bees.generated.yml` | one service per enabled node |
| `prometheus/targets/bee.generated.json` | scrape targets + `node`/`role`/`neighborhood` labels |
| `prometheus/rules/reserve.generated.yml` | per-node reserve ceilings (not scrapable — see PLAN.md §6) |
| `compose/enabled-nodes.generated.txt`, `ports.generated.txt` | plain-text derivatives so the Makefile needs no YAML parser |

### Ports

Assigned from `port_base` in `fleet.yml`: node *i* gets `api = port_base + 2i`, `p2p = api + 1`.

`port_base` defaults to **1733, deliberately not bee's 1633**. bee-factory occupies 1633–1642, and that overlap is dangerous rather than merely awkward — an API port collision is silent for read-only tools, so `make addresses` would report a *factory* node's wallet and you would send real funds to the wrong node. Two guards: the generator rejects fleet ports inside the factory range, and `make preflight` (run automatically by `up-bees` and `up-staggered`) refuses to start when any fleet port is already bound.

Generated files are committed so fleet changes show up as reviewable diffs, and so the deploy host doesn't need Node. Never hand-edit them.

Everything else is static: `compose/docker-compose.observer.yml` (Prometheus, Grafana, cAdvisor, node_exporter), `prometheus/prometheus.yml`, `prometheus/rules/alerts.yml`, and the Grafana provisioning.

`make help` lists every target.

---

## Testing locally, without mainnet or funds

The observer stack can be pointed at a local [bee-factory](https://github.com/ethersphere/bee-factory) cluster, which exercises the entire pipeline — scrape → labels → recording rules → dashboards → alerts — with no wallets, no postage, and no sync wait.

```bash
# 1. start the local cluster (images are cached after the first run)
cd ../bee-factory && node dist/cli.js start --tag v2.8.1

# 2. bring up the observer stack pointed at it
cd ../hawtch-hawtcher
make test-up
make test-check      # after ~30s
```

`make test-check` asserts the pipeline rather than just checking containers are alive: all bee targets up, each required metric family present, the `node` label applied, ceiling and free-chunk recording rules producing series, alert rules loaded without errors, and Grafana serving the provisioned dashboard against the `hawtch-prom` datasource.

```
19 passed, 0 failed
```

Then browse http://127.0.0.1:3000 (admin / `$GRAFANA_ADMIN_PASSWORD`, default `admin`).

```bash
make test-down       # stops the stack and discards its TSDB
```

**What this does and does not prove.** It validates plumbing: config syntax, label joins, rule evaluation, dashboard wiring. It does **not** validate measurements — factory nodes run a private network with a near-empty reserve and no real traffic, so the values are structurally correct but meaningless. `reserve_seconds_to_full` stays empty because nothing is growing.

Two local-only deviations, both noted in the files: the test stack scrapes via `host.docker.internal` rather than the docker network, and node_exporter mounts `/:/host:ro` instead of `:ro,rslave` because Docker Desktop rejects slave propagation. Production keeps `rslave`.

The test stack reuses the production container names so the Grafana provisioning works unchanged — so don't run both stacks on one host.

---

## Prerequisites

- Linux host with Docker and Compose v2. **cAdvisor and node_exporter need a Linux host** — they will not report meaningfully on macOS, so develop config locally if you like, but run for real on Linux.
- Node 20+ on whoever runs `make generate`. The deploy host needs only Docker and a shell — the Makefile reads generated text files rather than parsing `fleet.yml`.
- A **Gnosis Chain RPC endpoint**. Bee will not start without one, and eight nodes on a public endpoint will get rate-limited. Use your own node or a paid provider.
- Disk per PLAN.md §3: **250–500 GB, NVMe**. Not optional — see PLAN.md §4.1.

---

## First run

```bash
cp .env.example .env      # fill in PUBLIC_IP, GNOSIS_RPC_ENDPOINT, BEE_PASSWORD, GRAFANA_ADMIN_PASSWORD
make install
make validate             # generate + check the merged compose file
make up-observer          # prometheus, grafana, cadvisor, node-exporter
make up-bees              # just bee-1 while only bee-1 is enabled
```

`fleet.yml` ships with **only `bee-1` enabled** — phase 1 is validating one node end to end before spending money on eight.

Grafana and Prometheus bind to loopback. Reach them over a tunnel:

```bash
ssh -L 3000:localhost:3000 -L 9090:localhost:9090 <host>
```

---

## Funding the nodes

Each node generates its own wallet on first start, so it must be funded **after** it starts and **before** it can do anything useful.

```bash
make addresses
```

```
bee-1  (full)
  fund this:  0x9965507d1a55bcc2695c58ba16fb37d819b0a4dc
  overlay:    039d4f0ab1892a2241c2dada3b7b0a82c7e8f4db3c99c231352b43d4476a6e2f
  neighborhood: got 00000011, pinned 00000000 ✗ MISMATCH
```

Send to the `fund this` address:

- **xDAI** — gas. Every node needs it, including light nodes.
- **xBZZ** — postage, and chequebook deposit if `BEE_SWAP_ENABLE` stays on. Only the uploader nodes (5 and 7) buy postage batches, but all nodes need a funded chequebook to pay for bandwidth.

The command also checks the mined overlay against the `target_neighborhood` you pinned. A **MISMATCH means the node is not in the neighborhood you intended** — almost always because a nonce already existed in the statestore before `target_neighborhood` was set. Fix it before funding, not after: moving a node later means abandoning its reserve and re-syncing.

### Staking

Off by default (`storage_incentives_enable: false`). A staking node runs reserve sampling and joins the redistribution game, and that CPU lands squarely in the pullsync-vs-CPU correlation we're trying to measure. Turn it on deliberately, and treat it as a measurement decision.

---

## Volumes: what they actually protect

Each node gets a named volume mounted at `/home/bee/.bee` (the image's declared `VOLUME`, running as uid 999). Node identity comes from two *separate* places inside it:

| Address | Derived from | Lives in |
|---|---|---|
| **Ethereum** (what you fund) | the private key | `keys/swarm.key`, encrypted with `BEE_PASSWORD` |
| **Overlay** (position in Swarm) | key + networkID + **nonce** | the nonce is in `statestore` (`overlayV2_nonce`) |

Both are **static for the life of the volume**. Restarts, `make stop`, `make down`, host reboots — the addresses do not change.

The subtlety: `keys/` alone is not enough. Restore the key without the statestore and Bee finds no nonce, so it **re-mines a different overlay**. Also in the volume: `stamperstore` (postage stamp issuance state — matters on the uploaders) and the reserve, which is recoverable only by re-syncing.

```bash
make backup-keys          # keys/ + statestore + stamperstore -> ./backups/
```

Back up `BEE_PASSWORD` **separately** — the archives are encrypted with it and useless without it. The archives are taken while the nodes run, so the leveldb copies may be mid-write; `make stop` first for a guaranteed-consistent copy.

### Not losing funded wallets

Four layers, because this is the one irreversible failure mode in the project.

**1. Volumes are `external`.** Compose is not permitted to create or destroy them, so `docker compose down -v` — typed by hand, in a script, anywhere — skips them. Verified by rehearsal: a volume holding a planted key survived `down -v` intact. They must be created up front, which `make volumes` does (and every `up-*` target depends on it).

The explicit `name:` (`hawtch_<node>-data`) also decouples them from the compose project name, so running with a different `-p` can no longer silently address a different, empty volume.

**2. `docker volume prune` is still a real risk, and `external` does not stop it.** Prune deletes any volume no container references — and after `make down`, yours qualify. Two defences:

- **Prefer `make stop` over `make down`** while the fleet is funded. Stopped containers still reference their volumes, so prune leaves them alone.
- Volumes are labelled `hawtch.keep=true`, so a safe prune is:
  ```bash
  docker volume prune --filter "label!=hawtch.keep=true"
  ```
  `make down` prints this warning explicitly when it finishes.

**3. `make down` takes a backup first**, automatically. The cheapest moment to have a snapshot is just before touching anything.

**4. `make restore` puts it back.** Rehearsed end to end: archive, delete `keys/` and `statestore/`, restore, and the key and nonce come back with correct `999:999` ownership. It refuses while a node's container is running, since writing into a live leveldb corrupts it. **Rehearse this yourself before you need it** — an untested backup is a guess.

Deleting volumes deliberately requires `make destroy CONFIRM=delete-funded-volumes`, and it refuses outright if any node lacks a backup on disk.

The one thing none of this protects against is **disk failure or losing the server**. `./backups/` lives on the same host, so copy those archives somewhere else — plus `BEE_PASSWORD`, stored separately, since the archives are encrypted with it.

**One consolation from pinning neighborhoods:** if a statestore is lost, the node re-mines into the *same* `target_neighborhood` from `fleet.yml`. The overlay differs, but the neighborhood — the thing measurements actually depend on — is preserved. You lose the reserve to a re-sync, not the comparability of the fleet.

Two commands to be careful with: `docker compose down -v` and `docker volume prune`. Both destroy funded wallets. `make down` deliberately does not pass `-v`.

Named volumes are used rather than bind mounts because the image runs as uid 999; a bind-mounted host directory needs `chown 999:999` first or bee fails to write. If you prefer bind mounts for easier backup, chown first.

---

## Scaling to the full fleet

Once bee-1 is funded, syncing, and visible in Grafana:

1. Flip `enabled: true` for the nodes you want in `fleet.yml`.
2. `make validate`
3. `make up-staggered` — brings nodes up **one at a time with a 5 minute gap**.

Use `up-staggered`, not `up-bees`, for the full nodes. Four nodes pull-syncing simultaneously against one disk bottleneck each other, and the measured pullsync rate then partly describes your disk rather than the network (PLAN.md §4.1). Staggering keeps that contention out of the warmup data.

The generator refuses to render a fleet where full nodes have mixed `reserve_capacity_doubling`, because doubling sets `shallowReceiptTolerance` and mixed values make the receipt metrics incomparable between nodes.

---

## Day-2

```bash
make ps
make logs
make reload-prometheus    # after editing prometheus config — no TSDB restart
make addresses            # re-verify neighborhoods and check funding
```

Prometheus retains **90 days**, which the reserve-runway projection needs. Grafana dashboards are provisioned from `grafana/dashboards/*.json` with `allowUiUpdates: false` — UI edits are overwritten on reload, so export the JSON back into the repo to keep a change.

---

## Verifying config changes

```bash
make validate

# rules and scrape config, without deploying
docker run --rm -v "$PWD/prometheus:/etc/prometheus:ro" \
  --entrypoint promtool prom/prometheus:v2.54.1 \
  check config /etc/prometheus/prometheus.yml
```

---

## Sidecar probes

Everything above is **passive** — Prometheus scraping counters Bee already exposes. The two sidecars are **active**: they upload, download and time the result, because no Bee metric can express a round trip.

| Probe | Nodes | Measures |
|---|---|---|
| `latency` | 7 → 8 | Upload duration, download duration, verified round trip, retrieval attempts, throughput |
| `beefeeder` | 5 → 6 | Feed write duration, propagation to the paired reader, poll attempts, stale reads |

Both live in `sidecars/` as one TypeScript package on `bee-js`, sharing config parsing, postage handling and the run loop. They expose `/metrics` for Prometheus to scrape — nothing is pushed. Their compose services and scrape targets are generated from `fleet.yml`, so endpoints can't drift from the nodes they're meant to probe.

Configure them under `sidecars:` in `fleet.yml` (enable/disable, interval, payload size, feed topic). Secrets go in `.env`.

### Two design points that matter for correctness

**A round trip needs two distinct nodes.** If upload and download pointed at the same Bee, the download would be served from local storage and the number would mean nothing. The generator refuses to wire a probe whose pair is incomplete, and the probe itself refuses at startup if both URLs match.

**"The read succeeded" is not "the new update arrived."** A feed reader always returns the latest update it can find, so `beefeeder` writes a unique marker payload and polls until it reads *that* payload back. Reads returning an older update are counted separately as `hawtch_feed_stale_reads_total` — the reader is behind, not broken. Without this comparison, a stale read would be recorded as instant propagation. In testing this counter fired on 3 of 6 runs, so it is not a theoretical concern.

### Postage

The probes cannot upload without a usable batch, and postage exhaustion produces upload failures that look exactly like network failures — hence dedicated metrics and alerts.

- Preferred: buy batches yourself and pin `POSTAGE_BATCH_ID_LATENCY` / `POSTAGE_BATCH_ID_BEEFEEDER` in `.env`.
- Otherwise set `POSTAGE_AUTO_BUY=true`. **Off by default on purpose**: with auto-buy on, a crash-looping probe buys a fresh batch on every restart, and on mainnet that is real xBZZ each time. The probe logs the estimated cost before purchasing, and prefers reusing an existing usable batch.
- A batch that is nearly full or close to expiry is rejected at startup rather than adopted, so it cannot expire mid-measurement.

Postage is expressed as **size + duration** (`POSTAGE_SIZE_GB`, `POSTAGE_DURATION_DAYS`) rather than a raw `amount`, because the required amount depends on the current chain price — a hardcoded value is wrong on any day but the one it was written, and Bee rejects it outright.

### Running them

```bash
# against bee-factory, no real funds — the only way to exercise the postage path safely
make test-probes            # latency -> :9101/metrics, beefeeder -> :9102/metrics

# for real, after the fleet is up and funded
make up-sidecars
```

`make test-probes` runs them on the host against the factory cluster, which is pre-funded on the local Anvil chain.

---

## Not built yet

- Dashboards beyond `fleet-overview.json` and `probes.json`: per-node detail, uploader health, the pullsync-vs-CPU correlation view.
- v1: multi-server, geo-distribution, Ansible, private mesh, observer moved off the measured host.
