// Upload/download round-trip probe for the content-addressed pair (nodes 7-8).
//
// Uploads a unique payload via one node, then retrieves it via the other. Two
// distinct nodes is the whole point: a download from the uploading node would be
// served out of local storage and would measure nothing about the network.

import { Bee } from '@ethersphere/bee-js'
import { randomBytes } from 'node:crypto'
import { loadLatencyConfig } from './config.js'
import {
  downloadAttempts,
  downloadDuration,
  roundTripDuration,
  initProbeMetrics,
  serveMetrics,
  throughput,
  uploadDuration,
} from './metrics.js'
import { ensurePostageBatch, refreshBatchMetrics } from './postage.js'
import { StageError, describe, fatal, nowSeconds, runLoop, sleep } from './runner.js'

const cfg = loadLatencyConfig()
const uploader = new Bee(cfg.uploadUrl)
const downloader = new Bee(cfg.downloadUrl)

async function probe(batchId: string): Promise<void> {
  // Random payload per run, so retrieval can never be satisfied by a chunk
  // cached from an earlier run. A fixed payload would produce ever-faster
  // "latency" as caches warm.
  const payload = randomBytes(cfg.payloadBytes)

  const roundTripStart = nowSeconds()

  let reference: string
  const uploadStart = nowSeconds()
  try {
    const result = await uploader.uploadData(batchId, payload, {
      // deferred=false means the request only completes once the data has been
      // pushed to the network. With deferred=true we would be timing a local
      // disk write and calling it an upload.
      deferred: false,
    })
    reference = result.reference.toString()
  } catch (err) {
    throw new StageError('upload', `upload to ${cfg.uploadUrl} failed`, err)
  }
  const uploadSeconds = nowSeconds() - uploadStart
  uploadDuration.observe({ probe: cfg.probe }, uploadSeconds)
  throughput.set({ probe: cfg.probe, direction: 'upload' }, cfg.payloadBytes / Math.max(uploadSeconds, 0.001))

  // Retrieval can legitimately need a few attempts while the chunks settle into
  // their neighbourhoods, so poll until the timeout rather than failing on the
  // first miss. The attempt count is exported: a rising trend means retrieval is
  // degrading even when the final latency looks acceptable.
  let attempts = 0
  let lastError: unknown
  const deadline = roundTripStart + cfg.timeoutSeconds

  while (nowSeconds() < deadline) {
    attempts += 1
    const attemptStart = nowSeconds()
    try {
      const data = await downloader.downloadData(reference)
      const downloadSeconds = nowSeconds() - attemptStart

      if (!Buffer.from(data.toUint8Array()).equals(payload)) {
        // Not a latency problem: the network returned something else entirely.
        throw new StageError('verify', `downloaded ${data.length} bytes that do not match the upload`)
      }

      downloadDuration.observe({ probe: cfg.probe }, downloadSeconds)
      downloadAttempts.observe({ probe: cfg.probe }, attempts)
      roundTripDuration.observe({ probe: cfg.probe }, nowSeconds() - roundTripStart)
      throughput.set(
        { probe: cfg.probe, direction: 'download' },
        cfg.payloadBytes / Math.max(downloadSeconds, 0.001),
      )
      return
    } catch (err) {
      if (err instanceof StageError) throw err
      lastError = err
      await sleep(cfg.pollIntervalSeconds)
    }
  }

  downloadAttempts.observe({ probe: cfg.probe }, attempts)
  throw new StageError(
    'download',
    `${reference} not retrievable from ${cfg.downloadUrl} after ${attempts} attempts ` +
      `in ${cfg.timeoutSeconds}s (last error: ${describe(lastError)})`,
  )
}

async function main(): Promise<void> {
  initProbeMetrics(cfg.probe)
  serveMetrics(cfg.metricsPort, cfg.probe)

  const batchId = await ensurePostageBatch(uploader, cfg.postage, cfg.probe)
  console.log(
    `[${cfg.probe}] upload=${cfg.uploadUrl} download=${cfg.downloadUrl} ` +
      `payload=${cfg.payloadBytes}B interval=${cfg.intervalSeconds}s timeout=${cfg.timeoutSeconds}s`,
  )

  await runLoop({
    probe: cfg.probe,
    intervalSeconds: cfg.intervalSeconds,
    timeoutSeconds: cfg.timeoutSeconds,
    run: async () => {
      await probe(batchId)
      await refreshBatchMetrics(uploader, batchId, cfg.probe)
    },
  })
}

main().catch((err) => fatal(cfg.probe, err))
