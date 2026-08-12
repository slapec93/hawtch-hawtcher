// Shared fleet.yml loader and port math.
//
// Port assignment lives here and nowhere else. It used to be duplicated between
// generate.mjs and addresses.mjs, which is precisely how a tool ends up querying
// a different node than the one the compose file created.

import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import yaml from 'js-yaml'

export const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..')

// pkg/storer/storer.go: DefaultReserveCapacity = 1 << 22
export const DEFAULT_RESERVE_CAPACITY = 1 << 22
// pkg/node/node.go: maxAllowedDoubling = 1
export const MAX_ALLOWED_DOUBLING = 1

// bee's own default is 1633. We deliberately do NOT use it: bee-factory
// publishes 1633 + 2n for n in 0..4 (i.e. 1633-1642), so a fleet based at 1633
// collides with a local factory cluster. Worse than a bind failure, the
// collision is silent for read-only tools — `make addresses` would report a
// factory node's wallet as if it were ours, and you would fund the wrong node.
export const DEFAULT_PORT_BASE = 1733

export const FULL_ROLES = new Set(['full'])
export const KNOWN_ROLES = new Set([
  'full',
  'feed-upload',
  'feed-download',
  'data-upload',
  'data-download',
])

/** Load fleet.yml and resolve every node to a fully-specified shape. */
export function loadFleet() {
  const fleet = yaml.load(readFileSync(join(ROOT, 'fleet.yml'), 'utf8'))
  const defaults = fleet.defaults ?? {}
  const portBase = fleet.port_base ?? DEFAULT_PORT_BASE

  const nodes = (fleet.nodes ?? []).map((node, i) => {
    const apiPort = node.api_port ?? portBase + 2 * i
    const doubling = node.reserve_capacity_doubling ?? defaults.reserve_capacity_doubling ?? 0
    const isFull = FULL_ROLES.has(node.role)
    return {
      ...node,
      isFull,
      apiPort,
      p2pPort: node.p2p_port ?? apiPort + 1,
      doubling,
      cacheCapacity: node.cache_capacity ?? defaults.cache_capacity ?? 1000000,
      verbosity: node.verbosity ?? defaults.verbosity ?? 'info',
      incentives: node.storage_incentives_enable ?? defaults.storage_incentives_enable ?? false,
      // Only full nodes maintain a reserve, so only they get a ceiling.
      reserveCapacity: isFull ? (1 << doubling) * DEFAULT_RESERVE_CAPACITY : null,
    }
  })

  return { ...fleet, portBase, nodes, enabled: nodes.filter((n) => n.enabled) }
}
