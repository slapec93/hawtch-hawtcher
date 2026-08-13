# hawtch-hawtcher — Plan

A monitoring suite for **Swarm mainnet**, built around a purpose-designed 8-node Bee probe fleet.

The fleet is the *instrument*, not the subject: mainnet is what we're measuring. Named after the Dr. Seuss Hawtch-Hawtcher Bee-Watcher — and, fittingly, the watcher needs watching too.

**v0 scope: single host.** Multi-server and geo-distribution are deferred to v1. This removes the mesh VPN and Ansible entirely, at the cost of some measurement validity — the trade-offs are stated explicitly in [§4](#4-what-single-host-costs-us-read-this-before-trusting-v0-numbers) rather than discovered later.

---

## 1. Fleet roles

| Nodes | Role | Measures |
|---|---|---|
| 1–4 | Full nodes, **neighborhoods pinned** | Pullsync rate, reserve size + growth, connectivity |
| 5–6 | Feed upload/download pair | Feed propagation timing (beefeeder) |
| 7–8 | Content-addressed upload/download pair | Upload/download latency + bandwidth |
| all | — | Host CPU / load / RAM, full vs. light peer counts |

### Neighborhood pinning is retained in v0

Neighborhood placement is **independent of server count** — a node's overlay address derives from its key plus a mined nonce (`crypto.NewOverlayAddress`), not from where the host sits. So four nodes on one box can occupy four well-separated neighborhoods just as easily as four nodes in four regions. Nothing about dropping multi-server weakens this, and it stays in v0.

The corollary, relevant to v1: geo-distribution and neighborhood placement were always **orthogonal** axes. Geo buys network-path diversity (latency, peering, transit); neighborhood buys position in the overlay. v0 keeps the second and drops the first.

### Do not accept Bee's default neighborhood assignment

From `pkg/node/node.go`: if `--target-neighborhood` is empty and no nonce exists yet, Bee queries `--neighborhood-suggester` (default `api.swarmscan.io`) and mines into a suggested **under-replicated** neighborhood.

Wrong for a measurement fleet:

- sparse neighborhoods are atypical *by construction*, so measurements don't represent normal conditions;
- assignment is not reproducible;
- reseeding a node silently moves it.

**Decision: pin 4 well-separated neighborhoods in config and commit them.**

---

## 2. Architecture (v0)

```
┌─ Single host ─────────────────────────────────────────────┐
│                                                            │
│  bee-1  bee-2  bee-3  bee-4     (full, nbhd α β γ δ)      │
│  bee-5 ──▶ bee-6                (feed pair)               │
│  bee-7 ──▶ bee-8                (content pair)            │
│                                                            │
│  node_exporter    cAdvisor                                 │
│                                                            │
│  ┌── observer (same box in v0 — see §4) ───────┐           │
│  │  Prometheus   Grafana                        │           │
│  │  beefeeder sidecar   latency sidecar         │           │
│  └──────────────────────────────────────────────┘           │
└────────────────────────────────────────────────────────────┘
```

Everything scrapes over localhost. No VPN, no cross-region scrape config, no `remote_write`.

**Bee's API is unauthenticated** — bind every node's API to `127.0.0.1` (or the docker bridge), never `0.0.0.0`. On a single public host this is the one security item that matters.

### Port allocation

Each node needs an API port and a P2P port, assigned sequentially from `port_base` in `fleet.yml`: node *i* gets `api = port_base + 2i`, `p2p = api + 1`. Only the P2P ports need to be reachable from the internet.

**`port_base` is 1733, not bee's default 1633.** bee-factory publishes `1633 + 2n` for n in 0..4, i.e. 1633–1642, and overlapping with it is worse than a bind failure. The API collision is *silent* for read-only tools: `make addresses` would query a factory node and report its wallet as ours, so you would fund the wrong node. The generator rejects any fleet whose ports land in the factory range, and `make preflight` refuses to start if any fleet port is already bound.

### Why Prometheus + Grafana

Bee's metrics are already Prometheus-native, so custom collection would mean reimplementing scraping and retention for no gain. One query language across built-in and synthetic measurements is also what makes the pullsync-vs-CPU question a single PromQL expression.

### Provisioning

**docker-compose only.** With one host, Ansible earns nothing — the compose file *is* the deployment. v1 reintroduces Ansible when there's more than one box to keep consistent.

---

## 3. Host sizing

Derived from source constants (`pkg/storer/storer.go`, `pkg/node/node.go`):

```
reserveCapacity = (1 << ReserveCapacityDoubling) * DefaultReserveCapacity
DefaultReserveCapacity = 1 << 22    // 4,194,304 chunks  ≈ 16 GiB @ ~4 KB
maxAllowedDoubling     = 1          // doubling ∈ {0, 1} only
defaultCacheCapacity   = 1,000,000 chunks ≈ 4 GiB
```

| Component | Estimate |
|---|---|
| Full node (doubling 0) | ~16 GiB reserve + ~4 GiB cache + statestore overhead ≈ **25 GiB** |
| 4 full nodes | ≈ **100 GiB** |
| Nodes 5–8 (uploader/downloader roles) | a few GiB each |
| **Total disk, with headroom** | **250–500 GB SSD — NVMe strongly preferred (see §4)** |
| RAM | ~2 GiB/node under load → **32 GiB** |
| CPU | **8 cores** minimum |

Disk figures are estimates from chunk-count constants, not measurements; treat them as a floor and monitor actual usage.

### Reserve doubling is a measurement decision, not just a sizing one

`node.go:309`:

```go
shallowReceiptTolerance := maxAllowedDoubling - o.ReserveCapacityDoubling
```

With `maxAllowedDoubling = 1`, a node at doubling 0 has shallow-receipt tolerance **1**, and a node at doubling 1 has tolerance **0**. Since "normal vs. shallow receipts" is one of our headline measurements, **doubling must be uniform across nodes 1–4 unless we're deliberately studying its effect** — otherwise the nodes aren't comparable and the difference will look like a network finding.

Doubling also scales the minimum stake: `minStake = (1 << doubling) × MinimumStakeAmount`, where the contract constant is `1e17` wei = 0.1 BZZ (`pkg/storageincentives/staking/contract.go:23`). Verify the effective mainnet requirement before funding — the on-chain minimum has differed from this constant historically.

---

## 4. What single-host costs us — read this before trusting v0 numbers

Three real validity limits. None blocks v0; all three should be visible in the write-up of any result.

### 4.1 Disk I/O contention is the sharpest problem

Pullsync is I/O-heavy, and four full nodes syncing simultaneously against one disk will bottleneck *each other*. **The measured pullsync rate then partly describes our disk rather than the network** — precisely the metric we most want to trust.

Mitigations, in order of value:

1. NVMe, not SATA SSD, and certainly not network-attached storage.
2. **Stagger initial sync** — bring full nodes up one at a time rather than all four at once.
3. Export disk saturation (`node_exporter` I/O metrics) alongside pullsync rate, so contention is visible instead of invisible.

### 4.2 Host load is no longer attributable to one node

The headline question — *does pullsync rate drive CPU and load?* — gets harder with eight co-resident nodes. Per-container CPU from **cAdvisor stays valid and attributable**; host `load` and aggregate disk I/O do not, since seven other nodes contribute.

Practical stance for v0: use cAdvisor per-container CPU for attribution, and treat host load purely as a saturation signal. The clean version of this experiment needs one node per host, which is v1.

### 4.3 The observer runs on the measured host

Prometheus, Grafana, and both sidecars now burn CPU on the box being measured, and their load correlates with scrape activity — which correlates with node activity. Acceptable for v0 if made visible: **scrape cAdvisor for the Prometheus, Grafana, and sidecar containers too**, so their cost is quantified and can be subtracted rather than silently attributed to Bee.

### 4.4 Co-located pairs measure something narrower

With nodes 5–6 and 7–8 on the same host, the WAN path is gone from the measurement. What remains is propagation *through the Swarm network* (chunks still route via the network, not locally) with a localhost API round trip. That's a valid and arguably cleaner measure of the network itself — it just isn't user-experienced latency. Don't compare v0 numbers against v1's split-region numbers as though they measure the same thing.

---

## 5. What Bee `/metrics` already gives us

Bee exposes **298 metric families** on the **main API port** (`:1633/metrics` — the separate debug port merged in 2.x). Verified against a live node.

| Requirement | Metrics | Notes |
|---|---|---|
| Pullsync rate | `bee_pullsync_chunks_delivered`, `_offered`, `_wanted`, `_sent` | counters → `rate()` |
| Reserve size | `bee_localstore_reserve_size`, `_size_within_radius`, `bee_batchstore_radius`, `bee_batchstore_commitment` | see §6 ceiling caveat |
| Pushsync success vs. failure | `bee_pushsync_total_sent` vs. `_total_failed_send_attempts`, `_total_outgoing_errors`, `_total_handler_errors` | clean split |
| Normal vs. shallow receipts | `bee_pushsync_shallow_receipt`, `bee_pushsync_receipt_depth` | already instrumented; see §3 on doubling |
| Full vs. light connectivity | `bee_kademlia_currently_connected_peers` **and** `bee_lightnode_currently_connected_peers` (+ `_currently_disconnected_peers`) | two separate gauges, not one labeled metric |

**Open verification item:** those gauges are unlabeled, so the full/light split assumes kademlia's gauge counts only full nodes (light peers tracked separately in the lightnode container). Consistent with how the bin table works, but **not yet confirmed in source**. `GET /peers` returns a per-peer `fullNode: true|false` flag as an authoritative cross-check.

### Gaps requiring our own code

- **Host resources** — nothing in Bee's metrics. `node_exporter` plus **cAdvisor** for per-container attribution, which §4.2 makes essential rather than merely nice.
- **Feed propagation timing** — not expressible from Bee metrics. Needs the beefeeder sidecar.
- **Upload/download latency and bandwidth** — same shape, needs the latency sidecar.

---

## 6. Reserve capacity: the extrapolation works differently than expected

Reserve size is **bounded by a constant, not by disk**. With `maxAllowedDoubling = 1`, the ceiling is ≈16 GiB (doubling 0) or ≈32 GiB (doubling 1). On reaching it, the node evicts and storage radius steps up.

So *"capacity left until radius increase"* is:

```
ceiling − bee_localstore_reserve_size      (projected at observed fill rate)
```

— **not** free disk space.

**The ceiling is not exported as a metric.** There is no `bee_localstore_reserve_capacity` gauge; capacity only surfaces via the status/debug API (`pkg/storer/debug.go`). It must be injected as per-node fleet configuration, derived from each node's doubling setting.

---

## 7. Repo layout (v0)

```
hawtch-hawtcher/
├─ compose/
│  ├─ docker-compose.yml       # 8 bee nodes + exporters + observer stack
│  └─ bee/                     # per-node config templates
├─ prometheus/                 # scrape config, recording + alert rules
├─ grafana/                    # provisioned dashboards as JSON
├─ sidecars/
│  ├─ beefeeder/               # feed propagation timing → /metrics
│  └─ latency/                 # upload/download latency + bandwidth → /metrics
└─ fleet.yml                   # single source of truth
```

**`fleet.yml` is the keystone.** Node → role, target neighborhood, reserve doubling, ports. Prometheus targets, Grafana dashboard variables, compose service definitions, and reserve-capacity ceilings all derive from it, so the fleet is described exactly once. Keeping this indirection in v0 — even with one host — is what makes the v1 multi-server expansion a config change rather than a rewrite.

---

## 8. Sidecars — built

TypeScript on `bee-js`, one package with two entrypoints, each exposing `/metrics` for Prometheus to scrape rather than pushing. Compose services and scrape targets are generated from `fleet.yml`.

- **beefeeder** — writes a feed update via the uploader, polls the downloader until *that specific* update is readable, exports write duration, propagation duration, poll attempts and stale reads.
- **latency** — uploads a unique payload, downloads and verifies it from the paired node, exports upload/download/round-trip durations, retrieval attempts and throughput.

Three correctness properties, each learned or confirmed by running them:

1. **Two distinct nodes are mandatory.** Same-node upload/download is a local read and measures nothing. Enforced in both the generator and at probe startup.
2. **A feed read is not a fresh feed read.** Readers return the latest update they can find, so propagation is only measurable by comparing against a unique written marker. Stale reads are counted separately — this fired on 3 of 6 runs in testing.
3. **Payloads must be unique per run.** A fixed payload would be served from warm caches and report ever-improving "latency."

Both export failures as first-class metrics, by stage, because a silent sidecar and a healthy network look identical otherwise.

**Postage** is the fiddliest dependency: expressed as size + duration (the required `amount` depends on current chain price, so hardcoding it fails), auto-buy off by default so a restart loop cannot spend repeatedly, cost logged before purchase, and batches near exhaustion or expiry rejected rather than adopted.

---

## 9. Derived metrics

1. **Reserve runway** — recording rule projecting `bee_localstore_reserve_size` at observed fill rate toward the per-node ceiling from `fleet.yml`.
2. **Warmup vs. steady state** — fresh mainnet full nodes pull-sync for a long time before reaching steady state. Pullsync rate, reserve fill, and CPU during that window describe *warmup*, not normal operation. A marker (recorded timestamp, or a rule keyed on reserve fill) lets dashboards exclude it. In v0 this matters doubly, since staggered startup (§4.1) means the four nodes warm up at different times.

## 10. Dashboards

- Fleet overview
- Per-node detail
- Uploader health — pushsync success rate, shallow-receipt ratio
- Reserve runway
- **Correlation view** — `rate(bee_pullsync_chunks_delivered[5m])` against cAdvisor per-container CPU, restricted to steady-state, with disk saturation shown alongside so contention (§4.1) is legible

---

## 11. Phasing

| # | Step | Notes |
|---|---|---|
| 1 | `fleet.yml` schema + compose for **one** node | validate config generation end to end |
| 2 | Prometheus + Grafana + cAdvisor + node_exporter | confirm scraping, including observer self-metrics (§4.3) |
| 3 | Scale to 4 full nodes, pinned neighborhoods, **staggered** startup | then let them sync |
| 4 | Sidecars + uploader/downloader pairs | **code done and verified against bee-factory**; needs funded postage on mainnet |
| 5 | Derived rules, correlation dashboards, alerting | |

Sync time between steps 3 and 4 is unavoidable dead time — start the full nodes early even if the rest is unfinished.

### Deferred to v1

- Multi-server deployment, Ansible, private mesh
- Geo-distributed full nodes; split-region sidecar pairs
- Observer host moved off the measured box (fixes §4.2 and §4.3 properly)

---

## 12. Open items

- **Host** — provider and specs, against §3. NVMe is the one non-negotiable.
- **Funding** — xDAI for gas across 8 nodes; xBZZ for postage on the uploaders.
- **Staking** — do nodes 1–4 stake for redistribution? A staking node runs reserve sampling and joins the redistribution game, consuming CPU that lands in the correlation data. A measurement decision, not only a financial one.
- **Reserve doubling** — uniform value for nodes 1–4 (see §3). Recommend 0 unless there's a reason otherwise.
- **Neighborhood selection** — 4 well-separated neighborhoods can be proposed from the address space, but choosing them against *current* mainnet topology requires live network data.

---

## Appendix: verification status

| Claim | Status |
|---|---|
| 298 metric families on `:1633/metrics` | verified against live node |
| Pullsync / pushsync / receipt / reserve metrics exist | verified |
| `DefaultReserveCapacity = 1 << 22`, scaled by doubling | verified in source |
| `maxAllowedDoubling = 1`; `defaultCacheCapacity = 1e6` chunks | verified in source |
| `shallowReceiptTolerance = maxAllowedDoubling − doubling` | verified in source |
| Reserve capacity ceiling absent from `/metrics` | verified |
| `--target-neighborhood` + suggester default behavior | verified in source |
| `MinimumStakeAmount = 1e17` wei | verified in source; **effective mainnet minimum not confirmed** |
| Kademlia peer gauge counts full nodes only | **assumed, needs source confirmation** |
| Disk/RAM sizing in §3 | **estimated from constants, not measured** |

Live-node figures came from a local `bee-factory` cluster (v2.8.1) against a `bee` checkout at `v2.7.2-rc1-66-gfddc49e4`; source line references should be re-checked against whichever version is deployed.
