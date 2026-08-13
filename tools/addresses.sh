#!/usr/bin/env bash
# Prints each enabled node's Ethereum address (what you fund) and overlay
# address, and checks the overlay against the neighborhood pinned in fleet.yml.
#
# Deliberately shell + curl + python3 only: this runs on the deploy host, which
# has no Node toolchain. It reads compose/nodes.generated.txt rather than parsing
# fleet.yml, for the same reason.

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
LIST=compose/nodes.generated.txt

if [ ! -f "$LIST" ]; then
  echo "missing $LIST — run 'make generate' on a workstation and commit it" >&2
  exit 1
fi

unreachable=0
total=0

while read -r name role port neighborhood; do
  [ -z "${name:-}" ] && continue
  total=$((total + 1))

  # The queried endpoint is printed so a wrong answer is visible rather than
  # merely plausible: if another bee held this port, the output would otherwise
  # look entirely legitimate.
  echo "$name  ($role)  via 127.0.0.1:$port"

  body=$(curl -fsS -m 5 "http://127.0.0.1:$port/addresses" 2>/dev/null)
  if [ -z "$body" ]; then
    echo "  unreachable on 127.0.0.1:$port"
    echo "    node not started, still initialising, or its API is not listening"
    echo
    unreachable=$((unreachable + 1))
    continue
  fi

  echo "$body" | NEIGHBORHOOD="$neighborhood" python3 -c '
import json, os, sys

body = json.load(sys.stdin)
eth = body.get("ethereum", "?")
overlay = body.get("overlay", "?")
print("  fund this:  " + eth)
print("  overlay:    " + overlay)

target = os.environ.get("NEIGHBORHOOD", "-")
if target and target != "-":
    # Compare the pinned binary prefix against the overlay leading bits.
    nybbles = (len(target) + 3) // 4
    bits = "".join(bin(int(c, 16))[2:].zfill(4) for c in overlay[:nybbles])[:len(target)]
    ok = bits == target
    status = "OK" if ok else "MISMATCH"
    print("  neighborhood: got " + bits + ", pinned " + target + " " + status)
    if not ok:
        print("    Not in the pinned neighborhood. Usually means a nonce already")
        print("    existed in the statestore before target_neighborhood was set.")
        print("    Fix this BEFORE funding: moving a node later abandons its reserve.")
'
  echo
done < "$LIST"

if [ "$unreachable" -gt 0 ]; then
  echo "$unreachable/$total node(s) unreachable."
  echo "Run this on the docker host — the bee API is bound to loopback by design."
  echo "Check with: docker ps --filter name=hawtch-bee"
fi
