/**
 * SharedArrayBuffer layout and barrier for class P (SPEC-1 section 5.6).
 *
 * Shared by the main thread and the workers, so the offsets are computed once
 * from the config and both sides agree by construction rather than by comment.
 *
 * ## Why one buffer and not one per array
 *
 * A worker gets the SAB in its `workerData`. Passing fifteen of them and
 * reassembling in the right order is fifteen chances to get an offset wrong;
 * passing one and deriving every view from the same `layout()` is none.
 * Alignment matters: Float32Array and Uint32Array views need 4-byte-aligned
 * byte offsets and Uint16Array needs 2, so `layout` rounds every section up.
 */

import type { SimConfig, SimBuffers } from "./sim.ts";

export type Reduce = "private" | "binned";

/** Control words, in the Int32Array at the head of the buffer. */
export const CTL_SENSE = 0; // barrier phase, flipped by the last arriver
export const CTL_COUNT = 1; // threads still to arrive
export const CTL_STOP = 2; // 1 once the run is over
export const CTL_WORDS = 8; // padded so the two hot words share no cache line

export interface Layout {
  bytes: number;
  cells: number;
  agents: number;
  height: number;
  threads: number;
  reduce: Reduce;
  off: Record<string, number>;
}

function align(n: number, a: number): number {
  return (n + a - 1) & ~(a - 1);
}

export function layout(cfg: SimConfig, threads: number, reduce: Reduce): Layout {
  const cells = cfg.width * cfg.height;
  const agents = cfg.agents;
  const h = cfg.height;
  const t = threads;
  const binned = reduce === "binned";

  const off: Record<string, number> = {};
  let p = 0;
  const put = (name: string, bytes: number, a = 4) => {
    p = align(p, a);
    off[name] = p;
    p += bytes;
  };

  put("ctl", CTL_WORDS * 4, 64);
  put("grid", cells * 4);
  put("scratch", cells * 4);
  put("dep", cells * 4);
  put("ax", agents * 4);
  put("ay", agents * 4);
  put("adir", agents * 2, 2);
  put("arng", agents * 16);
  put("tickNs", t * 8, 8);

  if (binned) {
    put("aidx", agents * 4);
    put("sorted", agents * 4);
    put("counts", t * t * 4);
    put("offsets", t * t * 4);
    put("ybucket", h * 2, 2);
    put("rowcnt", t * h * 4);
    put("rowsum", h * 4);
  } else {
    // One full-grid deposit buffer per thread.
    put("priv", t * cells * 4);
  }

  return { bytes: align(p, 64), cells, agents, height: h, threads: t, reduce, off };
}

/** Every view onto the shared buffer, for one side of the divide. */
export interface SharedViews extends SimBuffers {
  ctl: Int32Array;
  tickNs: Float64Array;
  aidx: Int32Array;
  sorted: Int32Array;
  counts: Int32Array;
  offsets: Int32Array;
  ybucket: Uint16Array;
  rowcnt: Int32Array;
  rowsum: Int32Array;
  priv: Float32Array;
}

export function views(sab: SharedArrayBuffer, L: Layout): SharedViews {
  const { off, cells, agents, height: h, threads: t } = L;
  const binned = L.reduce === "binned";
  const empty4 = new Int32Array(0);

  return {
    ctl: new Int32Array(sab, off.ctl, CTL_WORDS),
    grid: new Float32Array(sab, off.grid, cells),
    scratch: new Float32Array(sab, off.scratch, cells),
    dep: new Float32Array(sab, off.dep, cells),
    ax: new Float32Array(sab, off.ax, agents),
    ay: new Float32Array(sab, off.ay, agents),
    adir: new Uint16Array(sab, off.adir, agents),
    arng: new Uint32Array(sab, off.arng, agents * 4),
    tickNs: new Float64Array(sab, off.tickNs, t),

    aidx: binned ? new Int32Array(sab, off.aidx, agents) : empty4,
    sorted: binned ? new Int32Array(sab, off.sorted, agents) : empty4,
    counts: binned ? new Int32Array(sab, off.counts, t * t) : empty4,
    offsets: binned ? new Int32Array(sab, off.offsets, t * t) : empty4,
    ybucket: binned ? new Uint16Array(sab, off.ybucket, h) : new Uint16Array(0),
    rowcnt: binned ? new Int32Array(sab, off.rowcnt, t * h) : empty4,
    rowsum: binned ? new Int32Array(sab, off.rowsum, h) : empty4,
    priv: binned ? new Float32Array(0) : new Float32Array(sab, off.priv, t * cells),
  };
}

/**
 * Sense-reversing barrier over two `Atomics` words.
 *
 * `Atomics.wait` parks on a futex, which is the right default for the same
 * reason the C reference defaults to a futex barrier: at 32 threads on 16
 * cores, spinners steal execution resources from their SMT siblings. The one
 * difference from C is forced rather than chosen -- `Atomics.wait` is illegal
 * on the main thread in a browser, and Node only allows it off the main thread
 * when the loop is not the event loop. Here the main thread *is* worker 0 for
 * the duration of the run, so it uses a short spin and then a yield instead.
 */
export class Barrier {
  private ctl: Int32Array;
  private n: number;
  private sense = 0;

  constructor(ctl: Int32Array, n: number) {
    this.ctl = ctl;
    this.n = n;
  }

  /** Called once by the owner before any worker starts. */
  reset(): void {
    Atomics.store(this.ctl, CTL_SENSE, 0);
    Atomics.store(this.ctl, CTL_COUNT, this.n);
  }

  /** `canWait` is false on the thread that may not block on a futex. */
  wait(canWait: boolean): void {
    const ctl = this.ctl;
    const target = this.sense ^ 1;
    this.sense = target;

    if (Atomics.sub(ctl, CTL_COUNT, 1) === 1) {
      // Last in: reload the counter, flip the sense, wake everyone.
      Atomics.store(ctl, CTL_COUNT, this.n);
      Atomics.store(ctl, CTL_SENSE, target);
      Atomics.notify(ctl, CTL_SENSE);
      return;
    }

    if (canWait) {
      while (Atomics.load(ctl, CTL_SENSE) !== target) {
        Atomics.wait(ctl, CTL_SENSE, target ^ 1);
      }
    } else {
      while (Atomics.load(ctl, CTL_SENSE) !== target) {
        // Spin. The owner thread cannot park, so this is the price of having
        // it participate as a worker rather than sit idle.
        Atomics.load(ctl, CTL_COUNT);
      }
    }
  }
}

/** Contiguous split of `[0, n)` into `parts`; part `i` is `[lo, hi)`. */
export function split(n: number, parts: number, i: number): [number, number] {
  const base = (n / parts) | 0;
  const rem = n % parts;
  const lo = i * base + (i < rem ? i : rem);
  return [lo, lo + base + (i < rem ? 1 : 0)];
}
