#!/usr/bin/env bash
# Asserts the local test stack is actually working, rather than merely running.
#
# Checks the full path: targets scraped -> bee metrics stored -> recording rules
# evaluated -> alerts loaded -> Grafana up with the dashboard provisioned.

set -uo pipefail

PROM=http://127.0.0.1:9090
GRAFANA=http://127.0.0.1:3000

# Take the Grafana password from .env unless it is already exported. Without this
# the API calls below fall back to admin:admin, get a 401, and report the
# dashboard and datasource as "missing" when the real problem is authentication.
if [ -z "${GRAFANA_ADMIN_PASSWORD:-}" ] && [ -f .env ]; then
  GRAFANA_ADMIN_PASSWORD=$(sed -n 's/^GRAFANA_ADMIN_PASSWORD=//p' .env | tail -1)
fi
GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-admin}"
pass=0
fail=0

ok()   { echo "  ✓ $1"; pass=$((pass + 1)); }
bad()  { echo "  ✗ $1"; fail=$((fail + 1)); }
info() { echo "  · $1"; }

# Extract a field from Prometheus JSON without depending on jq.
pq() { python3 -c "import json,sys;d=json.load(sys.stdin);print($1)" 2>/dev/null; }

echo "Prometheus"
if ! curl -fsS "$PROM/-/ready" >/dev/null 2>&1; then
  bad "not ready at $PROM — is the test stack up? (make test-up)"
  echo
  echo "$pass passed, $fail failed"
  exit 1
fi
ok "ready"

# --- targets -----------------------------------------------------------------
targets=$(curl -fsS "$PROM/api/v1/targets?state=active" 2>/dev/null)

for job in bee cadvisor node prometheus; do
  up=$(echo "$targets" | pq "sum(1 for t in d['data']['activeTargets'] if t['labels']['job']=='$job' and t['health']=='up')")
  total=$(echo "$targets" | pq "sum(1 for t in d['data']['activeTargets'] if t['labels']['job']=='$job')")
  up=${up:-0}; total=${total:-0}
  if [ "$total" = "0" ]; then
    bad "job '$job' has no targets"
  elif [ "$up" = "$total" ]; then
    ok "job '$job': $up/$total up"
  elif [ "$job" = "cadvisor" ] || [ "$job" = "node" ]; then
    # Expected to be flaky on Docker Desktop; not a config fault.
    info "job '$job': $up/$total up — normal on Docker Desktop, works on a Linux host"
  else
    bad "job '$job': only $up/$total up"
    echo "$targets" | pq "chr(10).join('      '+t['scrapeUrl']+' -> '+(t['lastError'] or '?') for t in d['data']['activeTargets'] if t['labels']['job']=='$job' and t['health']!='up')"
  fi
done

# --- bee metrics -------------------------------------------------------------
echo
echo "Bee metrics"
check_series() {
  local label=$1 query=$2 min=${3:-1}
  local n
  n=$(curl -fsS --get "$PROM/api/v1/query" --data-urlencode "query=$query" 2>/dev/null | pq "len(d['data']['result'])")
  n=${n:-0}
  if [ "$n" -ge "$min" ]; then ok "$label ($n series)"; else bad "$label — got $n series, expected >= $min"; fi
}

check_series "pullsync counters"      "bee_pullsync_chunks_delivered" 1
check_series "pushsync sent"          "bee_pushsync_total_sent" 1
check_series "shallow receipts"       "bee_pushsync_shallow_receipt" 1
check_series "reserve size"           "bee_localstore_reserve_size" 1
check_series "full peers gauge"       "bee_kademlia_currently_connected_peers" 1
check_series "light peers gauge"      "bee_lightnode_currently_connected_peers" 1
check_series "node label applied"     'bee_localstore_reserve_size{node!=""}' 1

# --- recording rules ---------------------------------------------------------
echo
echo "Recording rules"
check_series "reserve ceiling injected" "hawtch:reserve_capacity_chunks" 1
check_series "reserve free chunks"      "hawtch:reserve_free_chunks" 1
info "reserve_seconds_to_full is empty unless the reserve is growing — expected on an idle cluster"

# --- alerts ------------------------------------------------------------------
echo
echo "Alert rules"
rules=$(curl -fsS "$PROM/api/v1/rules" 2>/dev/null)
n_alerts=$(echo "$rules" | pq "sum(1 for g in d['data']['groups'] for r in g['rules'] if r['type']=='alerting')")
n_broken=$(echo "$rules" | pq "sum(1 for g in d['data']['groups'] for r in g['rules'] if r.get('health') not in ('ok','unknown'))")
[ "${n_alerts:-0}" -ge 6 ] && ok "${n_alerts} alert rules loaded" || bad "expected >= 6 alert rules, found ${n_alerts:-0}"
[ "${n_broken:-1}" = "0" ] && ok "no rules in error state" || bad "${n_broken} rule(s) in error state"

firing=$(echo "$rules" | pq "','.join(r['name'] for g in d['data']['groups'] for r in g['rules'] if r['type']=='alerting' and r['state']=='firing')")
[ -n "${firing:-}" ] && info "currently firing: $firing"

# --- grafana -----------------------------------------------------------------
echo
echo "Grafana"
if curl -fsS "$GRAFANA/api/health" >/dev/null 2>&1; then
  ok "healthy at $GRAFANA"
  # /api/search needs auth — without credentials this returns 401 and the check
  # can never genuinely pass.
  # Distinguish "cannot authenticate" from "not provisioned" — they need very
  # different fixes, and reporting the first as the second sends you hunting
  # through provisioning config for a password problem.
  code=$(curl -s -o /dev/null -w '%{http_code}' -u "admin:$GRAFANA_ADMIN_PASSWORD" "$GRAFANA/api/search?query=Fleet")
  if [ "$code" = "401" ] || [ "$code" = "403" ]; then
    bad "cannot authenticate to Grafana (HTTP $code) — GRAFANA_ADMIN_PASSWORD does not match"
    info "on a deployed host the password lives in .env; this script now reads it from there"
  else
    db=$(curl -fsS -u "admin:$GRAFANA_ADMIN_PASSWORD" "$GRAFANA/api/search?query=Fleet" 2>/dev/null | pq "len(d)")
    if [ "${db:-0}" -ge 1 ]; then
      ok "fleet dashboard provisioned"
    else
      bad "fleet dashboard not found (provisioning polls every 30s)"
    fi
  fi
  ds=$(curl -fsS -u "admin:$GRAFANA_ADMIN_PASSWORD" "$GRAFANA/api/datasources" 2>/dev/null | pq "sum(1 for x in d if x['uid']=='hawtch-prom')")
  [ "${ds:-0}" = "1" ] && ok "prometheus datasource provisioned (uid hawtch-prom)" \
    || bad "datasource uid hawtch-prom missing — provisioned dashboards will not resolve"
else
  bad "not responding at $GRAFANA"
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" = "0" ] || exit 1
