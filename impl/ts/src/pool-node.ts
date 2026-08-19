/**
 * Class-P driver: allocate the SharedArrayBuffer, seed it, start the workers,
 * and run as thread 0.
 *
 * ## Why the main thread is thread 0
 *
 * Spawning `threads` workers and having the main thread only wait would leave
 * one core idle and make `--threads 16` mean seventeen runnable threads. The
 * main thread does a worker's share instead. The one cost is that it cannot
 * use `Atomics.wait` -- Node forbids blocking the main thread's event loop --
 * so its barrier waits spin. At the thread counts that matter, one spinner out
 * of sixteen is cheaper than one idle core.
 */

import { Worker as NodeWorker } from "node:worker_threads";
import { fileURLToPath } from "node:url";
import { Sim, nowNs, hex32 } from "./sim.ts";
import type { Parsed } from "./cli.ts";
import { Barrier, layout, views } from "./shared.ts";
import { Worker, initYBucket } from "./parallel.ts";

export interface ParallelRun {
  sim: Sim;
  msTotal: number;
  tickMs: number[];
}

export async function runParallel(p: Parsed): Promise<ParallelRun> {
  if (p.cfg.update !== "deferred") {
    process.stderr.write(
      "error: --threads > 1 requires --update deferred.\n" +
        "       SPEC-1 'serial' makes an agent's deposit visible to the\n" +
        "       next agent in the same tick, which is a sequential\n" +
        "       dependency; see SPEC-1 section 5.5.\n",
    );
    process.exit(2);
  }
  if (typeof SharedArrayBuffer === "undefined") {
    process.stderr.write("error: SharedArrayBuffer is unavailable in this runtime.\n");
    process.exit(2);
  }

  const t = p.threads;
  const L = layout(p.cfg, t, p.reduce);
  const sab = new SharedArrayBuffer(L.bytes);
  const v = views(sab, L);

  // Seed the shared buffer once, on this thread: SPEC-1 section 3.3 is
  // sequential and the workers attach to the result.
  const sim = new Sim(p.cfg, v, true);
  if (p.reduce === "binned") initYBucket(v.ybucket, p.cfg.height, t);

  const barrier = new Barrier(v.ctl, t);
  barrier.reset();

  const adaptive = process.env.SLIMEBENCH_NO_REBALANCE === undefined;
  const total = p.warmup + p.ticks;

  const workerUrl = new URL("./worker-node.ts", import.meta.url);
  const workers: NodeWorker[] = [];
  const exits: Promise<void>[] = [];
  for (let tid = 1; tid < t; tid++) {
    const w = new NodeWorker(fileURLToPath(workerUrl), {
      workerData: { sab, layout: L, cfg: p.cfg, tid, threads: t, reduce: p.reduce, adaptive, ticks: total },
      // Node needs to be told to strip types in a worker too.
      execArgv: ["--experimental-strip-types", "--no-warnings"],
    });
    workers.push(w);
    exits.push(new Promise<void>((res, rej) => {
      w.on("exit", () => res());
      w.on("error", rej);
    }));
  }

  const me = new Worker(sim, v, barrier, 0, t, p.reduce, adaptive, false);

  for (let i = 0; i < p.warmup; i++) me.runTick();
  sim.nsAgents = 0;
  sim.nsDiffuse = 0;

  const tickMs: number[] = [];
  const tStart = nowNs();
  for (let i = 0; i < p.ticks; i++) {
    const a = nowNs();
    me.runTick();
    tickMs.push((nowNs() - a) / 1e6);

    if (p.hashEvery && (i + 1) % p.hashEvery === 0) {
      // Every worker is quiesced at the closing barrier of the tick, so the
      // grid is stable while this reads it.
      process.stderr.write(
        `tick ${i + 1} grid=${hex32(sim.hashGrid())} agents=${hex32(sim.hashAgents())}\n`,
      );
    }
  }
  const msTotal = (nowNs() - tStart) / 1e6;

  await Promise.all(exits);
  // Class P interleaves the phases across threads, so splitting the tick into
  // agent and diffusion time the way the serial path does would be
  // meaningless. Report wall time.
  sim.nsAgents = msTotal * 1e6;
  sim.nsDiffuse = 0;

  return { sim, msTotal, tickMs };
}
