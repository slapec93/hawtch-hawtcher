#!/usr/bin/env bash
# One-command install: bare Ubuntu/Debian host -> observer stack running.
#
#   sudo ./deploy/install.sh <login-user>
#
# Idempotent and resumable: safe to re-run after filling in the values it cannot
# invent. It does NOT start bee nodes and does NOT spend money — funding is
# manual by design, and node wallets only exist after first boot.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
REPO="$PWD"
TARGET_USER="${1:-${SUDO_USER:-}}"

if [ "$(id -u)" -ne 0 ]; then
  echo "run with sudo: sudo $0 <login-user>" >&2
  exit 1
fi
if [ -z "$TARGET_USER" ] || ! id "$TARGET_USER" >/dev/null 2>&1; then
  echo "usage: sudo $0 <login-user>   (the user that will run make)" >&2
  exit 1
fi

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }

# ---- 1. host prerequisites --------------------------------------------------

step "host prerequisites"
"$REPO/deploy/bootstrap.sh" "$TARGET_USER"

# ---- 2. .env ----------------------------------------------------------------

step "configuration"

gen() { openssl rand -hex 32; }

# Read a KEY=value from .env, empty if unset.
envval() { sed -n "s/^$1=//p" "$REPO/.env" 2>/dev/null | tail -1; }

# Set a KEY=value in .env, replacing any existing line.
envset() {
  local key=$1 val=$2
  if grep -q "^$key=" "$REPO/.env"; then
    # value may contain / and &, so use a delimiter unlikely to appear and escape
    python3 - "$REPO/.env" "$key" "$val" <<'PY'
import sys
path, key, val = sys.argv[1], sys.argv[2], sys.argv[3]
lines = open(path).read().split('\n')
out = [f'{key}={val}' if l.startswith(f'{key}=') else l for l in lines]
open(path, 'w').write('\n'.join(out))
PY
  else
    printf '%s=%s\n' "$key" "$val" >> "$REPO/.env"
  fi
}

if [ ! -f "$REPO/.env" ]; then
  cp "$REPO/.env.example" "$REPO/.env"
  echo "created .env from .env.example"
else
  echo ".env already exists — filling only what is empty"
fi
chmod 600 "$REPO/.env"

# Secrets we can generate safely. A generated 32-byte value beats a
# human-chosen one, provided it gets backed up — see the warning at the end.
for key in BEE_PASSWORD GRAFANA_ADMIN_PASSWORD FEED_PRIVATE_KEY; do
  if [ -z "$(envval "$key")" ]; then
    envset "$key" "$(gen)"
    echo "generated $key"
  else
    echo "$key already set — left alone"
  fi
done

# Public IP: prefer the address already on the default route, since that is what
# peers will actually reach. Fall back to an external lookup for NAT'd hosts.
if [ -z "$(envval PUBLIC_IP)" ]; then
  ip_guess=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
  if [ -z "$ip_guess" ]; then
    ip_guess=$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)
  fi
  if [ -n "$ip_guess" ]; then
    envset PUBLIC_IP "$ip_guess"
    echo "detected PUBLIC_IP=$ip_guess"
    echo "  verify this is the address peers reach — if the host is behind NAT,"
    echo "  set it to the external address and forward the P2P ports."
  else
    echo "could not detect PUBLIC_IP — set it manually"
  fi
fi

# ---- 3. what we cannot invent -----------------------------------------------

MISSING=()
[ -z "$(envval GNOSIS_RPC_ENDPOINT)" ] && MISSING+=("GNOSIS_RPC_ENDPOINT")
[ -z "$(envval PUBLIC_IP)" ] && MISSING+=("PUBLIC_IP")

chown -R "$TARGET_USER":"$TARGET_USER" "$REPO"

if [ ${#MISSING[@]} -gt 0 ]; then
  cat <<EOF

$(printf '\033[1m==> not finished\033[0m')

Still needed in .env:
$(printf '  %s\n' "${MISSING[@]}")

GNOSIS_RPC_ENDPOINT has no sensible default: bee will not start without it, and
six nodes on a public endpoint will be rate-limited. Use your own Gnosis node or
a paid provider.

Then re-run this script (it will pick up where it left off):
  sudo ./deploy/install.sh $TARGET_USER
EOF
  exit 0
fi

# ---- 4. bring up the observer ----------------------------------------------

step "config check"
make -C "$REPO" check-generated

step "firewall"
make -C "$REPO" firewall || echo "  (firewall step skipped — configure ufw manually)"

step "observer stack"
make -C "$REPO" up-observer

chown -R "$TARGET_USER":"$TARGET_USER" "$REPO"

# ---- 5. what remains, which is deliberately manual --------------------------

ENABLED=$(cat "$REPO/compose/enabled-nodes.generated.txt" 2>/dev/null || echo "?")

cat <<EOF

$(printf '\033[1m==> installed\033[0m')

Running: prometheus, grafana, cadvisor, node-exporter.
Fleet configured but NOT started: $ENABLED

$(printf '\033[1;33mBACK UP .env NOW, OFF THIS HOST.\033[0m')
BEE_PASSWORD encrypts every node wallet. Without it, the funds are unrecoverable
even with intact volumes and backups. FEED_PRIVATE_KEY must also stay stable, or
the beefeeder probe polls a feed nobody writes to.

Remaining steps, manual because they involve money:

  1. make up-staggered     start nodes one at a time (5 min apart)
  2. make addresses        print each node's address, and CHECK the
                           neighborhood line before sending anything
  3. fund each node        xDAI for gas; xBZZ for postage on bee-5 and bee-7
  4. make backup-keys      snapshot identity, then copy ./backups off-host
  5. make up-sidecars      probes, once nodes are funded and syncing

Dashboards are on loopback. From your workstation:
  ssh -L 3000:localhost:3000 -L 9090:localhost:9090 $TARGET_USER@$(envval PUBLIC_IP)

Log out and back in before running make yourself, so docker works without sudo.
EOF
