/**
 * Class-P worker (SPEC-1 section 5.6). One of these per thread beyond the
 * first; the main thread runs the same `Worker` class as thread 0.
 *
 * It attaches to the shared buffer and runs the tick loop to completion --
 * there is no per-tick message. postMessage round trips would cost more than
 * the phases they coordinate; the barrier in `shared.ts` is the only channel.
 */

import { parentPort, workerData } from "node:worker_threads";
import { Sim, type SimConfig } from "./sim.ts";
import { Barrier, views, type Layout, type Reduce } from "./shared.ts";
import { Worker } from "./parallel.ts";

interface Init {
  sab: SharedArrayBuffer;
  layout: Layout;
  cfg: SimConfig;
  tid: number;
  threads: number;
  reduce: Reduce;
  adaptive: boolean;
  ticks: number;
}

const d = workerData as Init;
const v = views(d.sab, d.layout);

// doInit = false: the main thread has already seeded the grid and the agents
// (SPEC-1 section 3.3) into this very buffer. Re-running init here would
// overwrite it with the same values from a different starting point -- and
// with several workers racing to do so.
const sim = new Sim(d.cfg, v, false);

const barrier = new Barrier(v.ctl, d.threads);
const w = new Worker(sim, v, barrier, d.tid, d.threads, d.reduce, d.adaptive, true);

for (let t = 0; t < d.ticks; t++) w.runTick();

parentPort?.postMessage({ tid: d.tid, done: true });
