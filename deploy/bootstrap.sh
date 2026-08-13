#!/usr/bin/env bash
# Prepares a fresh Ubuntu VPS to run hawtch-hawtcher. Idempotent — safe to re-run.
#
#   sudo ./deploy/bootstrap.sh <login-user>
#
# Installs Docker, the handful of tools the Makefile needs, and time sync. Does
# NOT start any node, fund anything, or write secrets: that stays manual.

set -euo pipefail

TARGET_USER="${1:-${SUDO_USER:-}}"

if [ "$(id -u)" -ne 0 ]; then
  echo "run with sudo: sudo $0 <login-user>" >&2
  exit 1
fi
if [ -z "$TARGET_USER" ]; then
  echo "usage: sudo $0 <login-user>   (the user that will run make)" >&2
  exit 1
fi
if ! id "$TARGET_USER" >/dev/null 2>&1; then
  echo "no such user: $TARGET_USER" >&2
  exit 1
fi

say() { printf '\n== %s\n' "$1"; }

# Fail up front on an unsupported distro rather than halfway through apt. The
# Docker repo path and the package names below are Debian-family specific.
say "os"
if [ ! -r /etc/os-release ]; then
  echo "no /etc/os-release — cannot identify this distro" >&2
  exit 1
fi
# shellcheck disable=SC1091
. /etc/os-release
echo "${PRETTY_NAME:-$NAME $VERSION_ID}  (id=$ID, codename=${VERSION_CODENAME:-none})"
echo "kernel: $(uname -srm)"

case "$ID" in
  ubuntu) DOCKER_REPO_DISTRO=ubuntu ;;
  debian) DOCKER_REPO_DISTRO=debian ;;
  *)
    cat >&2 <<EOF

Unsupported distro: $ID

This script targets Ubuntu or Debian: it uses apt, Docker's Debian-family
repository, ufw and chrony. On RHEL-family systems (rocky, almalinux, rhel,
fedora) the equivalents are dnf, Docker's centos repo, firewalld and chronyd —
the steps map over, but the commands differ.

The suite itself only needs Docker + Compose v2, so installing those by hand and
skipping this script is a valid path. Then: make firewall expects ufw, and
make preflight expects nc.
EOF
    exit 1
    ;;
esac

if [ -z "${VERSION_CODENAME:-}" ]; then
  echo "no VERSION_CODENAME in /etc/os-release — cannot build the Docker apt entry" >&2
  exit 1
fi

say "packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
# netcat-openbsd: `make preflight` uses nc. chrony: see the note below.
apt-get install -y -qq \
  ca-certificates curl gnupg git make netcat-openbsd chrony ufw jq

# Correct time is not cosmetic here. Prometheus timestamps every sample, the
# probes stamp their own last-success gauges, and alerts compare the two against
# time(). A drifting clock produces measurements that are wrong in ways that look
# like real findings.
say "time sync"
systemctl enable --now chrony
chronyc tracking | sed -n '1,3p' || true

say "docker"
if ! command -v docker >/dev/null 2>&1; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/$DOCKER_REPO_DISTRO/gpg" \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/$DOCKER_REPO_DISTRO $VERSION_CODENAME stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
else
  echo "docker already installed: $(docker --version)"
fi
systemctl enable --now docker

say "docker group for $TARGET_USER"
usermod -aG docker "$TARGET_USER"
echo "note: $TARGET_USER must re-login before docker works without sudo"

# Log rotation. Eight bee nodes at info verbosity produce a lot, and a full disk
# is a bad way to discover that — bee handles it poorly, and the reserve needs
# every byte it was sized for.
say "docker log rotation"
if [ ! -f /etc/docker/daemon.json ]; then
  mkdir -p /etc/docker
  cat > /etc/docker/daemon.json <<'JSON'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "50m", "max-file": "5" }
}
JSON
  systemctl restart docker
  echo "wrote /etc/docker/daemon.json"
else
  echo "/etc/docker/daemon.json exists — leaving it alone"
  echo "  ensure log rotation is configured, or 8 nodes will fill the disk"
fi

say "firewall"
# Default deny inbound, SSH allowed. P2P ports are opened separately by
# `make firewall`, which reads them from the generated port list so the rules
# cannot drift from fleet.yml.
ufw --force default deny incoming
ufw --force default allow outgoing
ufw allow OpenSSH
ufw --force enable
ufw status verbose | sed -n '1,6p'
echo
echo "P2P ports are NOT open yet. From the repo, run:  make firewall"

say "sanity"
printf 'cores:  %s\n' "$(nproc)"
printf 'memory: %s\n' "$(free -h | awk '/^Mem:/ {print $2}')"
printf 'disk:   %s\n' "$(df -h --output=avail / | tail -1 | tr -d ' ') available on /"
echo "block devices (want NVMe — see PLAN.md 4.1):"
lsblk -d -o NAME,SIZE,ROTA,MODEL | sed 's/^/  /'
echo
echo "ROTA=1 means spinning disk. Four full nodes pull-syncing against one"
echo "spindle will bottleneck each other and corrupt the pullsync measurement."

cat <<'NEXT'

== next
  1. re-login so docker works without sudo
  2. cp .env.example .env && edit it
       PUBLIC_IP              this host's public address
       GNOSIS_RPC_ENDPOINT    your own node or a paid provider
       BEE_PASSWORD           BACK THIS UP — it encrypts every wallet
       GRAFANA_ADMIN_PASSWORD
       FEED_PRIVATE_KEY       openssl rand -hex 32
  3. make firewall          open the P2P ports from fleet.yml
  4. make check-generated   confirm the committed config matches fleet.yml
  5. make up-observer       prometheus, grafana, exporters
  6. make up-staggered      nodes one at a time
  7. make addresses         fund each node, verify neighborhoods
NEXT
