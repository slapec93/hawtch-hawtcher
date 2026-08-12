#!/usr/bin/env node
// Prints each enabled node's Ethereum and overlay address.
//
// The Ethereum address is what you fund (xDAI for gas, xBZZ for postage). The
// overlay address is what determines the node's neighborhood — check it against
// the target_neighborhood you pinned in fleet.yml, because a mismatch means the
// node mined somewhere you did not intend.

import { loadFleet } from './fleet.mjs'

const nodes = loadFleet().enabled

if (nodes.length === 0) {
  console.error('no nodes enabled in fleet.yml')
  process.exit(1)
}

const rows = await Promise.all(
  nodes.map(async (node) => {
    try {
      const res = await fetch(`http://127.0.0.1:${node.apiPort}/addresses`, {
        signal: AbortSignal.timeout(5000),
      })
      if (!res.ok) return { node, error: `HTTP ${res.status}` }
      const body = await res.json()
      return { node, ethereum: body.ethereum, overlay: body.overlay }
    } catch (err) {
      return { node, error: err.name === 'TimeoutError' ? 'timeout' : err.message }
    }
  }),
)

for (const row of rows) {
  const { node } = row
  // The queried endpoint is printed so that a wrong answer is visible rather
  // than plausible: if this port belonged to some other bee on the host, the
  // output would otherwise look entirely legitimate.
  console.log(`${node.name}  (${node.role})  via 127.0.0.1:${node.apiPort}`)
  if (row.error) {
    console.log(`  unreachable on 127.0.0.1:${node.apiPort} — ${row.error}`)
    console.log()
    continue
  }
  console.log(`  fund this:  ${row.ethereum}`)
  console.log(`  overlay:    ${row.overlay}`)

  const target = node.target_neighborhood
  if (target) {
    // Compare the pinned prefix against the overlay's leading bits.
    const bits = [...row.overlay.slice(0, Math.ceil(target.length / 4))]
      .map((h) => parseInt(h, 16).toString(2).padStart(4, '0'))
      .join('')
      .slice(0, target.length)
    const ok = bits === String(target)
    console.log(`  neighborhood: got ${bits}, pinned ${target} ${ok ? '✓' : '✗ MISMATCH'}`)
    if (!ok) {
      console.log(
        '    The node did not mine into the pinned neighborhood. Most likely a nonce',
      )
      console.log(
        '    already existed in the statestore before target_neighborhood was set.',
      )
    }
  }
  console.log()
}

const unreachable = rows.filter((r) => r.error).length
if (unreachable) {
  console.log(`${unreachable}/${rows.length} node(s) unreachable.`)
  console.log('Run this on the docker host: the API is bound to loopback by design.')
}
