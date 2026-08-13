# Deploying to a VPS

For the v0 single-host setup. Read [PLAN.md §4](PLAN.md#4-what-single-host-costs-us-read-this-before-trusting-v0-numbers) first — it explains which measurements this topology can and cannot support.

## The short version

From a bare Ubuntu or Debian host:

```bash
sudo apt-get update && sudo apt-get install -y git
git clone git@github.com:slapec93/hawtch-hawtcher.git
cd hawtch-hawtcher
sudo ./deploy/install.sh $USER
```

That installs Docker and the tooling, generates the secrets it safely can, detects `PUBLIC_IP`, opens the P2P ports, and starts the observer stack. It stops and tells you what it cannot invent — principally `GNOSIS_RPC_ENDPOINT` — and is safe to re-run to pick up where it left off.

It deliberately stops short of starting nodes or spending anything. Funding is manual: wallets only exist after first boot, and sending money is not something a script should do on your behalf. Steps 4–8 below cover the rest.

The sections that follow explain each stage, and are worth reading before the first real deployment.

---

## 1. Pick a host

| | Minimum | Why |
|---|---|---|
| CPU | 8 cores | 8 bee nodes plus the observer stack |
| RAM | 32 GB | ~2 GB per node under load |
| Disk | 250–500 GB **NVMe** | ~25 GB per full node (16 GiB reserve + 4 GiB cache + overhead) |
| Network | unmetered or generous | pullsync moves real volume continuously |

**NVMe is the one non-negotiable.** Four full nodes pull-syncing against a spinning disk will bottleneck each other, and the measured pullsync rate then partly describes your disk rather than the network — the metric you most want to trust. `bootstrap.sh` prints `lsblk` with the `ROTA` column so you can check.

Note this is a chunky VPS. If budget forces a smaller box, reduce the node count in `fleet.yml` rather than under-provisioning disk — fewer honest nodes beat eight contended ones.

---

## 2. Bootstrap

Check the OS first — `bootstrap.sh` targets **Ubuntu or Debian**:

```bash
cat /etc/os-release        # ID and VERSION_CODENAME are what matter
hostnamectl                # OS, kernel, architecture in one
```

```bash
ssh <user>@<host>
git clone git@github.com:slapec93/hawtch-hawtcher.git
cd hawtch-hawtcher
sudo ./deploy/bootstrap.sh $USER
# re-login so docker works without sudo
```

On anything else the script exits immediately with an explanation rather than failing partway through `apt`. RHEL-family hosts map over conceptually (dnf, Docker's centos repo, firewalld, chronyd), but the commands differ — and since the suite itself only needs Docker + Compose v2, installing those by hand and skipping the script is a legitimate path. Just note that `make firewall` expects `ufw` and `make preflight` expects `nc`.

Installs Docker, `make`, `netcat` (used by `make preflight`), `jq`, `chrony`, and `ufw`; sets default-deny inbound with SSH allowed; configures Docker log rotation; and prints the host's specs.

Two details worth knowing:

- **Time sync (`chrony`) is not cosmetic.** Prometheus timestamps every sample, the probes stamp their own last-success gauges, and alerts compare the two against `time()`. A drifting clock yields measurements that are wrong in ways that look like real findings. We hit a clock step during development and it rendered a probe's age as negative.
- **Docker log rotation is configured** (50 MB × 5 per container). Eight nodes at `info` verbosity produce a lot, and Bee handles a full disk badly.

The deploy host needs **no Node toolchain**. Generated files are committed, and `make` reads them as plain text; `make check-generated` verifies they exist and aren't older than `fleet.yml`.

---

## 3. Configure

```bash
cp .env.example .env
$EDITOR .env
```

| Variable | Notes |
|---|---|
| `PUBLIC_IP` | This host's public address. Used for `BEE_NAT_ADDR`; without it, eight nodes behind one host advertise unreachable addresses and your peer-count measurements reflect that rather than the network. |
| `GNOSIS_RPC_ENDPOINT` | Required — Bee will not start without it. Eight nodes on a public endpoint will get rate-limited; use your own node or a paid provider. |
| `BEE_PASSWORD` | **Back this up off-box.** It encrypts every node's wallet; losing it loses the funds regardless of volumes. |
| `GRAFANA_ADMIN_PASSWORD` | Grafana binds to loopback only. |
| `FEED_PRIVATE_KEY` | `openssl rand -hex 32`. Must stay stable — a new key is a new feed, and the beefeeder reader would poll an address nobody writes to. |
| `POSTAGE_BATCH_ID_*` | Preferred over `POSTAGE_AUTO_BUY`. See [README](README.md#postage). |

Then open the P2P ports:

```bash
make firewall
```

That reads the generated port list, so the rules cannot drift from `fleet.yml`. It opens **only** P2P (1734, 1736 … 1748). API ports stay closed: Bee's API is unauthenticated and bound to `127.0.0.1`.

---

## 4. The fleet as configured

`fleet.yml` enables **6 of 8** nodes, tuned for an 8-core / 32 GB host:

| Nodes | Role | Enabled |
|---|---|---|
| bee-1, bee-2 | full | ✅ |
| bee-3, bee-4 | full | ❌ disabled |
| bee-5, bee-6 | feed pair | ✅ |
| bee-7, bee-8 | content pair | ✅ |

Full nodes are the expensive role — the only ones holding a reserve and pull-syncing, so they dominate CPU, RAM and especially disk I/O. Running two instead of four **halves the concurrent-sync contention** that is v0's sharpest measurement problem. The cost is coverage: two neighborhoods sampled instead of four.

The four light nodes are nearly free (no reserve, no pullsync) and they are what makes the probes valid, so they stay.

**Do not fold the probe pairs into the full nodes to save resources.** A full node asked to download a chunk it already holds in its reserve serves it locally, and the latency measurement becomes meaningless. Dedicated light nodes are a correctness requirement, not a luxury.

Rough budget on your box:

| | Used | Available |
|---|---|---|
| Disk | ~75 GB (50 GB reserves + light nodes + ~15 GB Prometheus at 90d) | 1 TB |
| RAM | ~12 GB (2×2 GB full, 4×1 GB light, ~4 GB observer) | 32 GB |
| CPU | 2 syncing nodes rather than 4 | 8 cores |

Enable bee-3 and bee-4 later once the host has demonstrably got headroom.

Verbosity is set to `warn` rather than `info` for the same reason: log write traffic lands on the same disk as the reserve and competes with pullsync. Raise it on a single node when debugging that node.

### Still start with one node

Even with headroom, phase 1 argues for validating **bee-1 alone** end to end first — it exercises funding, neighborhood mining and sync behaviour cheaply, and that is where surprises surface. Set `enabled: false` on the rest, then on a workstation:

```bash
make generate && git commit -am "fleet: bee-1 only" && git push
```

and `git pull` on the VPS. Generation needs Node; the VPS only consumes the output.

---

## 5. Start

```bash
make check-generated     # committed config matches fleet.yml
make up-observer         # prometheus, grafana, cadvisor, node-exporter
make up-staggered        # nodes one at a time, 5 min apart
```

Use `up-staggered`, not `up-bees`, for the full nodes. Simultaneous initial sync means they contend for the same disk, and that contention lands inside your warmup data ([PLAN.md §4.1](PLAN.md#41-disk-io-contention-is-the-sharpest-problem)).

`make preflight` runs automatically and refuses to start if any fleet port is already bound.

---

## 6. Fund

```bash
make addresses
```

Wallets are generated on **first boot**, so this only works after step 5. For each node:

- **xDAI** for gas — every node, including the light ones.
- **xBZZ** for postage on the uploaders (5 and 7), plus chequebook deposits.

**Check the neighborhood line before sending anything.** A `✗ MISMATCH` means the node did not mine into the neighborhood you pinned; fixing it afterwards means abandoning its reserve and re-syncing.

---

## 7. Verify and protect

```bash
make ps
make backup-keys        # keys + statestore + stamperstore -> ./backups/
```

Then **copy `./backups/` and `BEE_PASSWORD` off the host.** Everything else survives container churn, but not the loss of the VPS. See [README](README.md#not-losing-funded-wallets) for the full set of guards.

Reach the dashboards over a tunnel:

```bash
ssh -L 3000:localhost:3000 -L 9090:localhost:9090 <user>@<host>
```

Then http://localhost:3000 → **Hawtch · Fleet overview**.

### Exposing Grafana instead

Both services bind to loopback by default. Grafana can be exposed — it has its own login — via `.env`:

```bash
GRAFANA_BIND=0.0.0.0
GRAFANA_PORT=3000
GRAFANA_ALLOW_CIDR=203.0.113.0/24   # strongly recommended; empty means any source
```

```bash
make up-observer          # recreate with the new binding
make firewall-grafana     # open the port, honouring GRAFANA_ALLOW_CIDR
```

**Prometheus is not exposable, deliberately.** Its port binding is hardcoded to `127.0.0.1` and takes no variable, because Prometheus has **no authentication at all** — anyone who reaches it can read every metric and enumerate the fleet. Grafana is the front door; use a tunnel for ad-hoc PromQL.

Three things to get right before opening the port:

1. **Use a strong admin password.** `openssl rand -hex 32`. `deploy/install.sh` generates one automatically. An exposed Grafana with `admin/admin` is compromised within hours.
2. **Restrict the source** with `GRAFANA_ALLOW_CIDR` if you can — your office or VPN range. This is worth far more than any Grafana-level hardening.
3. **Prefer TLS.** Over plain HTTP the admin password crosses the network in cleartext, so anyone on the path can read it. With a domain, the clean answer is a reverse proxy that obtains certificates automatically (Caddy needs about five lines), then:
   ```bash
   GRAFANA_BIND=127.0.0.1                        # proxy reaches it locally
   GRAFANA_ROOT_URL=https://hawtch.example.org
   GRAFANA_COOKIE_SECURE=true                    # secure cookies + HSTS
   ```

Sign-up is disabled, external snapshots and analytics are off, and a content security policy is set regardless of binding.

If you want the TLS proxy, say so and I'll add it — it needs a domain pointed at the host.

---

## 8. Probes, once nodes are funded and synced

```bash
make up-sidecars
```

They need their paired nodes running and a usable postage batch, so this comes last.

---

## Reboots

Containers use `restart: unless-stopped` and Docker is enabled at boot, so the fleet comes back by itself. It comes back **all at once**, though, which reintroduces the disk contention that `up-staggered` avoids — after an unplanned reboot, expect a period of contended warmup data, and check the disk-saturation panel before trusting pullsync numbers from that window.

## Day-to-day

| | |
|---|---|
| `make ps` / `make logs` | status, tail |
| `make addresses` | re-verify funding and neighborhoods |
| `make backup-keys` | snapshot identity |
| `make stop` | **prefer over `make down` while funded** — stopped containers still reference their volumes, so `docker volume prune` leaves them alone |
| `make reload-prometheus` | reloads rules and targets |

One caveat on that last one: `prometheus.yml` is bind-mounted as a *single file*, so editing it creates a new inode the container never sees. Rules and targets are directory mounts and reload fine; a change to `prometheus.yml` itself needs `docker restart hawtch-prometheus`.

## Updating

```bash
git pull
make check-generated
make up-bees            # recreates changed containers; volumes are external and untouched
```

Bumping `bee_image` in `fleet.yml` requires regenerating on a workstation and committing, as in step 4.
