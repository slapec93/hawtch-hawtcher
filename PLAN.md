# hawtch-hawtcher — Plan

A monitoring suite for **Swarm mainnet**, built around a purpose-designed 8-node Bee probe fleet.

The fleet is the *instrument*, not the subject: mainnet is what we're measuring. Named after the Dr. Seuss Hawtch-Hawtcher Bee-Watcher — and, fittingly, the watcher needs watching too (see [Observer effect](#the-observer-effect-is-a-real-constraint)).

---

## 1. Fleet roles

| Nodes | Role | Measures |
|---|---|---|
| 1–4 | Full nodes, geo-distributed, **neighborhoods pinned** | Pullsync rate, reserve size + growth, connectivity |
| 5–6 | Feed upload/download pair, **split across regions** | Feed propagation timing (beefeeder) |
| 7–8 | Content-addressed upload/download pair, **split across regions** | Upload/download latency + bandwidth |
| all | — | Host CPU / load / RAM, full vs. light peer counts |

### Geo-distribution and overlay neighborhood are orthogonal

A node's overlay address derives from its key plus a mined nonce (`crypto.NewOverlayAddress`). A server in Singapore is no more likely to occupy a different neighborhood than a second VM in the same rack.

- **Geo-spread** buys network-path diversity: latency, peering, transit quality.
- **Neighborhood placement** buys position in the overlay address space, and is controlled separately via `--target-neighborhood` (binary format, e.g. `111111001`).

Both are controlled deliberately, and independently.

### Neighborhood assignment: pin explicitly, do not accept the default

From `pkg/node/node.go`: if `--target-neighborhood` is empty and no nonce exists yet, Bee queries `--neighborhood-suggester` (default `api.swarmscan.io`) and mines into a suggested **under-replicated** neighborhood.

That default is wrong for a measurement fleet:

- sparse neighborhoods are atypical *by construction*, so measurements don't represent normal conditions;
- assignment is not reproducible;
- reseeding a node silently moves it.

**Decision: pin 4 well-separated neighborhoods in config and commit them.**

---

## 2. Architecture

```
┌─ Region A ──────────┐  ┌─ Region B ──────────┐  ┌─ Region C ───────────┐
│ bee-1 (full, nbhd α)│  │ bee-3 (full, nbhd γ)│  │ bee-2 (full, nbhd β) │
│ bee-5 (feed  ↑)     │  │ bee-6 (feed  ↓)     │  │ bee-4 (full, nbhd δ) │
│ bee-7 (data  ↑)     │  │ bee-8 (data  ↓)     │  │                      │
│ node_exporter       │  │ node_exporter       │  │ node_exporter        │
│ cAdvisor            │  │ cAdvisor            │  │ cAdvisor             │
└──────────┬──────────┘  └──────────┬──────────┘  └──────────┬───────────┘
           └──────────── private mesh ──────────────────────┘
                              │
                   ┌──────────┴──────────┐
                   │  Observer host      │  ← off-box, never measured
                   │  Prometheus         │
                   │  Grafana            │
                   │  beefeeder sidecar  │
                   │  latency sidecar    │
                   └─────────────────────┘
```

Region split depends on final server inventory. Two invariants: each sidecar pair straddles two regions, and the observer host is never itself a measured host.

### Why Prometheus + Grafana

Bee's metrics are already Prometheus-native. Custom collection would mean reimplementing scraping and retention for no gain. Keeping built-in and synthetic measurements in one query language is also what makes cross-cutting questions (pullsync rate vs. CPU) answerable in a single PromQL expression.

### The observer effect is a real constraint

A headline goal is *"how does pullsync rate affect CPU and load?"* If Prometheus, Grafana, and the sidecars run on a measured host, the monitoring stack's own CPU burn lands inside the measurement — and it correlates with scrape activity, which correlates with node activity. **The stack runs off-box.**

### Transport

The Bee API is unauthenticated by default and must never be publicly reachable. Options:

1. **Private mesh** (WireGuard or Tailscale) with Bee bound to a private interface — *preferred: fewest moving parts.*
2. Per-server Prometheus agent doing authenticated `remote_write` to the central instance.

### Provisioning

Ansible driving docker-compose per host. Reproducible, no control plane to operate. Kubernetes costs more than it returns at 8 nodes.

---

## 3. What Bee `/metrics` already gives us

Bee exposes **298 metric families** on the **main API port** (`:1633/metrics` — the separate debug port merged in 2.x). Verified against a live node.

| Requirement | Metrics | Notes |
|---|---|---|
| Pullsync rate | `bee_pullsync_chunks_delivered`, `_offered`, `_wanted`, `_sent` | counters → `rate()` |
| Reserve size | `bee_localstore_reserve_size`, `_size_within_radius`, `bee_batchstore_radius`, `bee_batchstore_commitment` | see ceiling caveat below |
| Pushsync success vs. failure | `bee_pushsync_total_sent` vs. `_total_failed_send_attempts`, `_total_outgoing_errors`, `_total_handler_errors` | clean split |
| Normal vs. shallow receipts | `bee_pushsync_shallow_receipt`, `bee_pushsync_receipt_depth` | already instrumented |
| Full vs. light connectivity | `bee_kademlia_currently_connected_peers` **and** `bee_lightnode_currently_connected_peers` (+ `_currently_disconnected_peers`) | two separate gauges, not one labeled metric |

**Open verification item:** those gauges are unlabeled, so the full/light split assumes kademlia's gauge counts only full nodes (light peers tracked separately in the lightnode container). Consistent with how the bin table works, but **not yet confirmed in source**. `GET /peers` returns a per-peer `fullNode: true|false` flag as an authoritative cross-check.

### Gaps requiring our own code

- **Host resources** — nothing in Bee's metrics. `node_exporter` per host, plus **cAdvisor** for per-container attribution (with 8 containers, "which node is burning CPU" is the actual question).
- **Feed propagation timing** — not expressible from Bee metrics. Needs the beefeeder sidecar.
- **Upload/download latency and bandwidth** — same shape, needs the latency sidecar.

---

## 4. Reserve capacity: the extrapolation works differently than expected

Reserve size is **bounded by a constant, not by disk**. From `pkg/storer/storer.go` and `pkg/node/node.go`:

```
reserveCapacity = (1 << ReserveCapacityDoubling) * DefaultReserveCapacity
DefaultReserveCapacity = 1 << 22   // 4,194,304 chunks
```

At ~4 KB/chunk that ceiling is ≈16 GiB, ≈32 GiB, or ≈64 GiB depending on each node's doubling setting. On reaching it, the node evicts and storage radius steps up.

So *"capacity left until radius increase"* is:

```
ceiling − bee_localstore_reserve_size      (projected at observed fill rate)
```

— **not** free disk space.

**The ceiling is not exported as a metric.** There is no `bee_localstore_reserve_capacity` gauge; capacity only surfaces via the status/debug API (`pkg/storer/debug.go`). It must therefore be injected as per-node fleet configuration, derived from each node's doubling setting.

---

## 5. Repo layout

```
hawtch-hawtcher/
├─ ansible/            # provisioning: roles for bee, exporters, observer
│  ├─ inventory/       # servers, regions, per-node role + neighborhood
│  └─ roles/
├─ compose/            # docker-compose per host profile (probe / observer)
├─ prometheus/         # scrape config, recording + alert rules
├─ grafana/            # provisioned dashboards as JSON
├─ sidecars/
│  ├─ beefeeder/       # feed propagation timing → /metrics
│  └─ latency/         # upload/download latency + bandwidth → /metrics
└─ fleet.yml           # single source of truth
```

**`fleet.yml` is the keystone.** Node → role, region, target neighborhood, reserve doubling. Ansible inventory, Prometheus targets, Grafana dashboard variables, and reserve-capacity ceilings all derive from it, so the fleet is described exactly once.

---

## 6. Sidecars

TypeScript on `bee-js`, each exposing `/metrics` for Prometheus to scrape rather than pushing.

- **beefeeder** — writes a feed update via the region-A uploader, polls the region-B downloader until it resolves, exports the delta as a histogram plus a failure counter.
- **latency** — uploads a known-size payload, downloads it from the paired node, exports upload/download duration and derived bandwidth.

Both require postage batches on the uploader nodes. Both **must** export failures as first-class metrics: a silent sidecar and a healthy network otherwise look identical.

---

## 7. Derived metrics

1. **Reserve runway** — recording rule projecting `bee_localstore_reserve_size` at observed fill rate toward the per-node ceiling from `fleet.yml`.
2. **Warmup vs. steady state** — fresh mainnet full nodes pull-sync for a long time before reaching steady state. Pullsync rate, reserve fill, and CPU during that window describe *warmup*, not normal operation. A marker (recorded timestamp, or a rule keyed on reserve fill) lets dashboards exclude it. Without this, weeks of early data silently misrepresent the network.

## 8. Dashboards

- Fleet overview
- Per-node detail
- Uploader health — pushsync success rate, shallow-receipt ratio
- Reserve runway
- **Correlation view** — `rate(bee_pullsync_chunks_delivered[5m])` against cAdvisor per-container CPU on shared time axes, restricted to steady-state. This is the "does pullsync drive CPU/load?" question.

---

## 9. Phasing

| # | Step | Notes |
|---|---|---|
| 1 | `fleet.yml` schema + Ansible skeleton | validated against **one** node on one server |
| 2 | Prometheus + Grafana on observer host | confirm cross-mesh scraping works |
| 3 | Scale to 4 full nodes, pinned neighborhoods | then let them sync |
| 4 | Sidecars + uploader/downloader pairs | |
| 5 | Derived rules, correlation dashboards, alerting | |

Sync time between steps 3 and 4 is unavoidable dead time — start the full nodes early even if the rest is unfinished.

---

## 10. Open items

These gate step 1:

- **Server inventory** — how many hosts, which provider and regions, what specs? Full nodes need persistent disk sized for the reserve ceiling plus cache headroom.
- **Mesh choice** — Tailscale (fast, external dependency) or WireGuard (self-managed, no third party)?
- **Funding** — xDAI for gas across 8 nodes; xBZZ for postage on the uploaders.
- **Staking** — do nodes 1–4 stake for redistribution? A staking node runs reserve sampling and participates in the redistribution game, consuming CPU that will appear in the correlation data. This is a measurement decision, not just a financial one.
- **Neighborhood selection** — 4 well-separated neighborhoods can be proposed from the address space, but choosing them against *current* mainnet topology requires live network data.

---

## Appendix: verification status

| Claim | Status |
|---|---|
| 298 metric families on `:1633/metrics` | verified against live node |
| Pullsync / pushsync / receipt / reserve metrics exist | verified |
| `DefaultReserveCapacity = 1 << 22`, scaled by doubling | verified in source |
| Reserve capacity ceiling absent from `/metrics` | verified |
| `--target-neighborhood` + suggester default behavior | verified in source |
| Kademlia peer gauge counts full nodes only | **assumed, needs source confirmation** |

Live-node figures came from a local `bee-factory` cluster (v2.8.1) against a `bee` checkout at `v2.7.2-rc1-66-gfddc49e4`; source line references should be re-checked against whichever version is deployed.
