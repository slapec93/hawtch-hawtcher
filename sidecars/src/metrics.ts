// Prometheus metrics, exposed on /metrics for scraping — the probes never push.
//
// Every probe exports its failures as first-class metrics. A silent sidecar and
// a healthy network look identical on a dashboard, so absence of latency data
// must be distinguishable from good latency.

import { createServer } from 'node:http'
import { Registry, Counter, Gauge, Histogram, collectDefaultMetrics } from 'prom-client'

export const registry = new Registry()
collectDefaultMetrics({ register: registry })

// Round trips through Swarm span a wide range: sub-second on a warm path,
// tens of seconds when retrieval has to walk the network. Linear buckets would
// put nearly everything in one or two of them.
const DURATION_BUCKETS = [0.1, 0.25, 0.5, 1, 2, 5, 10, 20, 30, 60, 120, 300]

export const runs = new Counter({
  name: 'hawtch_probe_runs_total',
  help: 'Probe runs by outcome',
  labelNames: ['probe', 'result'] as const,
  registers: [registry],
})

export const stageFailures = new Counter({
  name: 'hawtch_probe_stage_failures_total',
  help: 'Probe failures by the stage that failed',
  labelNames: ['probe', 'stage'] as const,
  registers: [registry],
})

export const lastRunTimestamp = new Gauge({
  name: 'hawtch_probe_last_run_timestamp_seconds',
  help: 'Unix timestamp of the last completed probe run, successful or not',
  labelNames: ['probe'] as const,
  registers: [registry],
})

export const lastSuccessTimestamp = new Gauge({
  name: 'hawtch_probe_last_success_timestamp_seconds',
  help: 'Unix timestamp of the last successful probe run',
  labelNames: ['probe'] as const,
  registers: [registry],
})

export const postageBatchInfo = new Gauge({
  name: 'hawtch_probe_postage_batch_utilization',
  help: 'Utilization of the postage batch in use (a probe stops working when its batch fills or expires)',
  labelNames: ['probe', 'batch_id'] as const,
  registers: [registry],
})

export const postageBatchTtl = new Gauge({
  name: 'hawtch_probe_postage_batch_ttl_seconds',
  help: 'Estimated seconds until the postage batch in use expires',
  labelNames: ['probe', 'batch_id'] as const,
  registers: [registry],
})

// ---- latency probe ----------------------------------------------------------

export const uploadDuration = new Histogram({
  name: 'hawtch_latency_upload_duration_seconds',
  help: 'Time to upload a payload with deferred=false, i.e. including the push to the network',
  labelNames: ['probe'] as const,
  buckets: DURATION_BUCKETS,
  registers: [registry],
})

export const downloadDuration = new Histogram({
  name: 'hawtch_latency_download_duration_seconds',
  help: 'Time for the final, successful download attempt from the paired node',
  labelNames: ['probe'] as const,
  buckets: DURATION_BUCKETS,
  registers: [registry],
})

export const roundTripDuration = new Histogram({
  name: 'hawtch_latency_roundtrip_duration_seconds',
  help: 'Upload start to successful download, including retrieval retries',
  labelNames: ['probe'] as const,
  buckets: DURATION_BUCKETS,
  registers: [registry],
})

export const downloadAttempts = new Histogram({
  name: 'hawtch_latency_download_attempts',
  help: 'Download attempts needed before the payload was retrievable',
  labelNames: ['probe'] as const,
  buckets: [1, 2, 3, 5, 8, 13, 21, 34, 55],
  registers: [registry],
})

export const throughput = new Gauge({
  name: 'hawtch_latency_bytes_per_second',
  help: 'Payload size divided by duration for the most recent run',
  labelNames: ['probe', 'direction'] as const,
  registers: [registry],
})

// ---- feed probe -------------------------------------------------------------

export const feedWriteDuration = new Histogram({
  name: 'hawtch_feed_write_duration_seconds',
  help: 'Time to write a feed update via the uploader node',
  labelNames: ['probe'] as const,
  buckets: DURATION_BUCKETS,
  registers: [registry],
})

export const feedPropagationDuration = new Histogram({
  name: 'hawtch_feed_propagation_duration_seconds',
  help: 'From completed write to the new update being readable at the paired node',
  labelNames: ['probe'] as const,
  buckets: DURATION_BUCKETS,
  registers: [registry],
})

export const feedPollAttempts = new Histogram({
  name: 'hawtch_feed_poll_attempts',
  help: 'Reads at the downloader before the new update appeared',
  labelNames: ['probe'] as const,
  buckets: [1, 2, 3, 5, 8, 13, 21, 34, 55],
  registers: [registry],
})

export const feedStaleReads = new Counter({
  name: 'hawtch_feed_stale_reads_total',
  help: 'Reads that returned an older update than the one just written',
  labelNames: ['probe'] as const,
  registers: [registry],
})

export const feedSequence = new Gauge({
  name: 'hawtch_feed_sequence',
  help: 'Sequence number of the most recent update written',
  labelNames: ['probe'] as const,
  registers: [registry],
})

/** Serve /metrics. Nothing is pushed; Prometheus scrapes this. */
export function serveMetrics(port: number, probe: string): void {
  const server = createServer(async (req, res) => {
    if (req.url === '/metrics') {
      res.writeHead(200, { 'Content-Type': registry.contentType })
      res.end(await registry.metrics())
      return
    }
    if (req.url === '/healthz') {
      res.writeHead(200, { 'Content-Type': 'text/plain' })
      res.end('ok\n')
      return
    }
    res.writeHead(404)
    res.end()
  })
  server.listen(port, () => console.log(`[${probe}] metrics on :${port}/metrics`))
}
