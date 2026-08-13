// Postage batch acquisition.
//
// This is the fiddliest part of both probes: a probe cannot upload without a
// usable batch, and a batch silently stops working when it fills up or expires.
// Both conditions are exported as metrics so the dashboards can show a probe
// failing for postage reasons rather than network reasons.

import type { Bee, PostageBatch } from '@ethersphere/bee-js'
import { Duration, Size } from '@ethersphere/bee-js'
import type { PostageConfig } from './config.js'
import { postageBatchInfo, postageBatchTtl } from './metrics.js'

export class PostageError extends Error {}

/**
 * Return the id of a usable batch, preferring reuse over purchase.
 *
 * Purchase requires POSTAGE_AUTO_BUY=true. Without that guard a crash-looping
 * probe would buy a fresh batch on every restart, which on mainnet is real money.
 */
export async function ensurePostageBatch(bee: Bee, cfg: PostageConfig, probe: string): Promise<string> {
  if (cfg.batchId) {
    const batch = await findBatch(bee, cfg.batchId)
    if (!batch) throw new PostageError(`POSTAGE_BATCH_ID ${cfg.batchId} not found on this node`)
    assertUsable(batch, cfg)
    report(batch, probe)
    console.log(
      `[${probe}] using configured batch ${cfg.batchId} ` +
        `(${batch.usageText} used, ${batch.remainingSize.toFormattedString()} free, ` +
        `expires in ${batch.duration.toDays().toFixed(1)}d)`,
    )
    return cfg.batchId
  }

  const reusable = await findReusableBatch(bee, cfg)
  if (reusable) {
    report(reusable, probe)
    console.log(`[${probe}] reusing batch ${reusable.batchID.toString()}`)
    return reusable.batchID.toString()
  }

  if (!cfg.autoBuy) {
    throw new PostageError(
      'no usable postage batch found, and POSTAGE_AUTO_BUY is not enabled. ' +
        'Buy a batch and set POSTAGE_BATCH_ID, or set POSTAGE_AUTO_BUY=true to let the ' +
        'probe purchase one. Auto-buy is off by default so a restart loop cannot spend ' +
        'repeatedly.',
    )
  }

  const size = Size.fromGigabytes(cfg.sizeGigabytes)
  const duration = Duration.fromDays(cfg.durationDays)

  // Log what it will cost before spending it. On mainnet this is real xBZZ, and
  // a silent purchase is a bad thing to discover in a wallet balance later.
  try {
    const cost = await bee.getStorageCost(size, duration)
    console.log(
      `[${probe}] buying ${cfg.sizeGigabytes}GB for ${cfg.durationDays}d ` +
        `— estimated cost ${cost.toSignificantDigits(6)} BZZ`,
    )
  } catch (err) {
    console.warn(`[${probe}] could not estimate storage cost: ${(err as Error).message}`)
  }

  const batchId = await bee.buyStorage(size, duration, {
    label: `hawtch-${probe}`,
    waitForUsable: true,
  })
  console.log(`[${probe}] bought batch ${batchId.toString()}`)
  return batchId.toString()
}

/** Refresh the exported utilization/TTL for the batch in use. */
export async function refreshBatchMetrics(bee: Bee, batchId: string, probe: string): Promise<void> {
  try {
    const batch = await findBatch(bee, batchId)
    if (batch) report(batch, probe)
  } catch {
    // Non-fatal: losing batch telemetry should not stop the probe measuring.
  }
}

function report(batch: PostageBatch, probe: string): void {
  const id = batch.batchID.toString()
  // bee-js already derives these: `usage` is the utilization ratio and `duration`
  // wraps the API's batchTTL. Recomputing them from depth/bucketDepth by hand is
  // how the two drift apart.
  postageBatchInfo.set({ probe, batch_id: id }, batch.usage)
  postageBatchTtl.set({ probe, batch_id: id }, batch.duration.toSeconds())
}

async function findBatch(bee: Bee, batchId: string): Promise<PostageBatch | undefined> {
  const all = await bee.getPostageBatches()
  return all.find((b) => b.batchID.toString() === batchId)
}

async function findReusableBatch(bee: Bee, cfg: PostageConfig): Promise<PostageBatch | undefined> {
  const all = await bee.getPostageBatches()
  return all.find((batch) => {
    if (!batch.usable) return false
    // Leave headroom: a batch that is nearly full will start rejecting uploads
    // mid-run, which would look like network failures. Also require some TTL, or
    // the probe adopts a batch that expires under it.
    if (batch.duration.toSeconds() < cfg.minTtlSeconds) return false
    return batch.remainingSize.toBytes() >= cfg.minRemainingBytes
  })
}

function assertUsable(batch: PostageBatch, cfg: PostageConfig): void {
  const id = batch.batchID.toString()
  if (!batch.usable) throw new PostageError(`batch ${id} is not usable yet`)

  if (batch.remainingSize.toBytes() < cfg.minRemainingBytes) {
    throw new PostageError(
      `batch ${id} has only ${batch.remainingSize.toFormattedString()} left ` +
        `(minimum ${Size.fromBytes(cfg.minRemainingBytes).toFormattedString()}); uploads will start failing`,
    )
  }
  if (batch.duration.toSeconds() < cfg.minTtlSeconds) {
    throw new PostageError(
      `batch ${id} expires in ${batch.duration.toDays().toFixed(1)}d, below the ` +
        `${(cfg.minTtlSeconds / 86400).toFixed(1)}d minimum; it would expire mid-measurement`,
    )
  }
}
