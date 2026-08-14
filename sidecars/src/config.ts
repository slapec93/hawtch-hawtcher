// Environment parsing. Fails loudly at startup on bad config, because a probe
// that starts with the wrong endpoints reports plausible numbers about the wrong
// thing — worse than not starting at all.

export class ConfigError extends Error {}

function required(name: string): string {
  const value = process.env[name]
  if (!value) throw new ConfigError(`${name} is required`)
  return value
}

function optional(name: string, fallback: string): string {
  return process.env[name] || fallback
}

function int(name: string, fallback: number): number {
  const raw = process.env[name]
  if (!raw) return fallback
  const parsed = Number(raw)
  if (!Number.isFinite(parsed) || parsed <= 0) {
    throw new ConfigError(`${name} must be a positive number, got "${raw}"`)
  }
  return parsed
}

function bool(name: string, fallback: boolean): boolean {
  const raw = process.env[name]
  if (raw === undefined) return fallback
  return raw === 'true' || raw === '1'
}

function url(name: string): string {
  const value = required(name)
  try {
    new URL(value)
  } catch {
    throw new ConfigError(`${name} must be a URL, got "${value}"`)
  }
  return value.replace(/\/$/, '')
}

export interface CommonConfig {
  probe: string
  uploadUrl: string
  downloadUrl: string
  metricsPort: number
  intervalSeconds: number
  timeoutSeconds: number
  pollIntervalSeconds: number
  postage: PostageConfig
}

export interface PostageConfig {
  batchId?: string
  autoBuy: boolean
  // Expressed as size + duration rather than a raw amount/depth. The required
  // `amount` depends on the current chain price, so a hardcoded value is wrong
  // on any day but the one it was written — bee rejects it outright with
  // "Amount has to be at least N".
  sizeMegabytes: number
  durationDays: number
  minRemainingBytes: number
  minTtlSeconds: number
}

export function loadCommon(defaults: { probe: string; metricsPort: number }): CommonConfig {
  const uploadUrl = url('UPLOAD_BEE_URL')
  const downloadUrl = url('DOWNLOAD_BEE_URL')

  // Measuring a round trip through the network requires two distinct nodes. If
  // both point at the same Bee, the "download" is served from local storage and
  // the numbers silently describe nothing.
  if (uploadUrl === downloadUrl) {
    throw new ConfigError(
      `UPLOAD_BEE_URL and DOWNLOAD_BEE_URL are both ${uploadUrl}. ` +
        `A round trip needs two different nodes, otherwise the download is served locally ` +
        `and the measurement is meaningless.`,
    )
  }

  return {
    probe: optional('PROBE_NAME', defaults.probe),
    uploadUrl,
    downloadUrl,
    metricsPort: int('METRICS_PORT', defaults.metricsPort),
    intervalSeconds: int('INTERVAL_SECONDS', 300),
    timeoutSeconds: int('TIMEOUT_SECONDS', 120),
    pollIntervalSeconds: int('POLL_INTERVAL_SECONDS', 1),
    postage: {
      batchId: process.env.POSTAGE_BATCH_ID || undefined,
      // Deliberately off by default. A crash-looping probe with auto-buy enabled
      // would purchase a fresh batch on every restart, burning real xBZZ.
      autoBuy: bool('POSTAGE_AUTO_BUY', false),
      // Megabyte granularity, and small by default. bee-js maps a requested
      // size to a batch depth, and depth is what you pay for: 1 GB lands on
      // depth 21 (~7.9 xBZZ for 30d at current price) while 10 MB lands on the
      // practical floor of depth 19 (~2.0 xBZZ). The probes upload kilobytes, so
      // the floor is right; batches are mutable and recycle their slots.
      sizeMegabytes: int('POSTAGE_SIZE_MB', 10),
      durationDays: int('POSTAGE_DURATION_DAYS', 30),
      // Headroom so a batch does not fill or expire mid-measurement, which would
      // surface as network failures rather than a postage problem.
      minRemainingBytes: int('POSTAGE_MIN_REMAINING_BYTES', 16 * 1024 * 1024),
      minTtlSeconds: int('POSTAGE_MIN_TTL_SECONDS', 24 * 3600),
    },
  }
}

export function loadLatencyConfig() {
  const common = loadCommon({ probe: 'latency', metricsPort: 9101 })
  return { ...common, payloadBytes: int('PAYLOAD_BYTES', 102400) }
}

export function loadFeedConfig() {
  const common = loadCommon({ probe: 'beefeeder', metricsPort: 9102 })
  return {
    ...common,
    // The feed owner. Must be stable across restarts: a new key means a new feed,
    // so the reader would look for updates at an address nobody is writing to.
    feedPrivateKey: required('FEED_PRIVATE_KEY'),
    feedTopic: optional('FEED_TOPIC', 'hawtch-hawtcher/beefeeder'),
  }
}
