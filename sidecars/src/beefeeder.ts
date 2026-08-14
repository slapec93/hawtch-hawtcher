// Feed propagation probe for the feed pair (nodes 5-6).
//
// Writes a feed update via one node and polls the other until that *specific*
// update becomes readable. The subtlety: a feed reader always returns the latest
// update it can find, so "the read succeeded" is not the same as "the new update
// arrived". Without comparing payloads, a reader serving a stale update would be
// recorded as instant propagation.

import { Bee, PrivateKey, Topic } from '@ethersphere/bee-js'
import { loadFeedConfig } from './config.js'
import {
  feedPollAttempts,
  feedPropagationDuration,
  feedSequence,
  feedStaleReads,
  feedWriteDuration,
  initProbeMetrics,
  serveMetrics,
} from './metrics.js'
import { ensurePostageBatch, refreshBatchMetrics } from './postage.js'
import { StageError, describe, fatal, nowSeconds, runLoop, sleep } from './runner.js'

const cfg = loadFeedConfig()
const uploader = new Bee(cfg.uploadUrl)
const downloader = new Bee(cfg.downloadUrl)

const signer = new PrivateKey(cfg.feedPrivateKey)
const owner = signer.publicKey().address()
const topic = Topic.fromString(cfg.feedTopic)

const writer = uploader.makeFeedWriter(topic, signer)
const reader = downloader.makeFeedReader(topic, owner)

let sequence = 0

async function probe(batchId: string): Promise<void> {
  sequence += 1
  // The payload identifies this specific update, which is what makes "has the
  // new update arrived?" answerable rather than guessed.
  const marker = `hawtch:${sequence}:${Math.floor(nowSeconds() * 1000)}`
  const expected = Buffer.from(marker, 'utf8')

  const writeStart = nowSeconds()
  try {
    await writer.uploadPayload(batchId, expected)
  } catch (err) {
    throw new StageError('feed-write', `writing update ${sequence} via ${cfg.uploadUrl} failed`, err)
  }
  const writeSeconds = nowSeconds() - writeStart
  feedWriteDuration.observe({ probe: cfg.probe }, writeSeconds)
  feedSequence.set({ probe: cfg.probe }, sequence)

  // Propagation is measured from write completion, so it excludes the write
  // itself — that is reported separately as feed_write_duration_seconds.
  const propagationStart = nowSeconds()
  const deadline = propagationStart + cfg.timeoutSeconds
  let attempts = 0
  let lastError: unknown

  while (nowSeconds() < deadline) {
    attempts += 1
    try {
      const result = await reader.downloadPayload()
      const got = Buffer.from(result.payload.toUint8Array())

      if (got.equals(expected)) {
        feedPropagationDuration.observe({ probe: cfg.probe }, nowSeconds() - propagationStart)
        feedPollAttempts.observe({ probe: cfg.probe }, attempts)
        return
      }

      // A valid read of an older update. Counting these separately distinguishes
      // "the reader cannot see the feed at all" from "the reader is behind".
      feedStaleReads.inc({ probe: cfg.probe })
    } catch (err) {
      // Before the very first update exists, the reader legitimately 404s.
      lastError = err
    }
    await sleep(cfg.pollIntervalSeconds)
  }

  feedPollAttempts.observe({ probe: cfg.probe }, attempts)
  throw new StageError(
    'feed-propagation',
    `update ${sequence} not visible at ${cfg.downloadUrl} after ${attempts} reads ` +
      `in ${cfg.timeoutSeconds}s (last error: ${describe(lastError)})`,
  )
}

async function main(): Promise<void> {
  initProbeMetrics(cfg.probe)
  serveMetrics(cfg.metricsPort, cfg.probe)

  const batchId = await ensurePostageBatch(uploader, cfg.postage, cfg.probe)
  console.log(
    `[${cfg.probe}] upload=${cfg.uploadUrl} download=${cfg.downloadUrl} ` +
      `feed owner=${owner.toChecksum()} topic="${cfg.feedTopic}" interval=${cfg.intervalSeconds}s`,
  )

  // The reader must look at the same feed the writer writes to. Logging the owner
  // makes a mismatched FEED_PRIVATE_KEY obvious instead of showing up as
  // permanent propagation timeouts.
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
