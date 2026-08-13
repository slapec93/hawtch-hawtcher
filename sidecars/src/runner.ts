// Probe loop scaffolding shared by both sidecars.
//
// Rules the loop enforces:
//   - a failing run never kills the process; it increments counters and the next
//     run happens on schedule, because a dead probe measures nothing
//   - a run that hangs is abandoned at the timeout, so one stuck retrieval cannot
//     stall every later measurement
//   - config errors DO kill the process at startup, since a misconfigured probe
//     reports confident numbers about the wrong thing

import { lastRunTimestamp, lastSuccessTimestamp, runs, stageFailures } from './metrics.js'

/** Thrown by probes to attribute a failure to a named stage. */
export class StageError extends Error {
  constructor(
    readonly stage: string,
    message: string,
    readonly cause?: unknown,
  ) {
    super(message)
  }
}

export const sleep = (seconds: number) => new Promise((resolve) => setTimeout(resolve, seconds * 1000))

export function nowSeconds(): number {
  return Date.now() / 1000
}

/** Reject if `promise` has not settled within `seconds`. */
export async function withTimeout<T>(promise: Promise<T>, seconds: number, stage: string): Promise<T> {
  let timer: NodeJS.Timeout | undefined
  try {
    return await Promise.race([
      promise,
      new Promise<never>((_, reject) => {
        timer = setTimeout(() => reject(new StageError(stage, `timed out after ${seconds}s`)), seconds * 1000)
      }),
    ])
  } finally {
    if (timer) clearTimeout(timer)
  }
}

export interface RunLoopOptions {
  probe: string
  intervalSeconds: number
  timeoutSeconds: number
  run: () => Promise<void>
}

export async function runLoop({ probe, intervalSeconds, timeoutSeconds, run }: RunLoopOptions): Promise<void> {
  // eslint-disable-next-line no-constant-condition
  while (true) {
    const started = nowSeconds()
    try {
      await withTimeout(run(), timeoutSeconds, 'run')
      runs.inc({ probe, result: 'success' })
      lastSuccessTimestamp.set({ probe }, nowSeconds())
    } catch (err) {
      const stage = err instanceof StageError ? err.stage : 'unknown'
      runs.inc({ probe, result: 'failure' })
      stageFailures.inc({ probe, stage })
      console.error(`[${probe}] run failed at stage "${stage}": ${describe(err)}`)
    } finally {
      lastRunTimestamp.set({ probe }, nowSeconds())
    }

    // Keep a steady cadence rather than a fixed gap, so a slow run does not
    // stretch the sampling interval and distort rate() calculations.
    const elapsed = nowSeconds() - started
    await sleep(Math.max(1, intervalSeconds - elapsed))
  }
}

export function describe(err: unknown): string {
  if (err instanceof StageError && err.cause) return `${err.message}: ${describe(err.cause)}`
  if (err instanceof Error) return err.message
  return String(err)
}

/** Exit non-zero on startup problems; let the container restart policy handle it. */
export function fatal(probe: string, err: unknown): never {
  console.error(`[${probe}] fatal: ${describe(err)}`)
  process.exit(1)
}
