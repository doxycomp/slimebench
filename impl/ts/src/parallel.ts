/**
 * The class-P tick, run identically by the main thread and every worker
 * (SPEC-1 section 5.6).
 *
 * Both reduction strategies, the same phase order and the same deposit order
 * as the C reference, so `binned` is bit-identical to the single-threaded run
 * here too.
 *
 * The agent rule and the diffusion stencil are not reimplemented: this file
 * calls `Sim.agentRange` and `Sim.diffuseRows`, the same methods the
 * single-threaded path uses. That is the whole point -- a second copy of the
 * rule is a copy that will drift.
 */

import { Sim } from "./sim.ts";
import { Barrier, split, type Reduce, type SharedViews } from "./shared.ts";

export class Worker {
  readonly sim: Sim;
  private v: SharedViews;
  private b: Barrier;
  private tid: number;
  private t: number;
  private reduce: Reduce;
  private adaptive: boolean;
  private canWait: boolean;
  private deposit: number;
  private height: number;
  private cells: number;
  private agents: number;
  private log2w: number;

  constructor(
    sim: Sim,
    v: SharedViews,
    b: Barrier,
    tid: number,
    threads: number,
    reduce: Reduce,
    adaptive: boolean,
    canWait: boolean,
  ) {
    this.sim = sim;
    this.v = v;
    this.b = b;
    this.tid = tid;
    this.t = threads;
    this.reduce = reduce;
    this.adaptive = adaptive;
    this.canWait = canWait;
    this.deposit = sim.cfg.deposit;
    this.height = sim.cfg.height;
    this.cells = sim.cfg.width * sim.cfg.height;
    this.agents = sim.cfg.agents;
    this.log2w = sim.log2w;
  }

  /**
   * One tick. Ends with a barrier, so on return the whole pool is quiesced.
   *
   * Six barriers for `binned`, matching the C reference's five phase barriers
   * plus its master/worker handshake.
   *
   * The buffer swap needs no synchronisation at all here, which is the one
   * place JavaScript's model helps: each worker owns a private `Sim` object
   * holding *views* onto the shared buffer, so swapping `grid` and `scratch`
   * is a local reference exchange every worker performs identically. In C and
   * Rust the same swap is shared mutable state and costs a sync point.
   *
   * The rebalance overlaps the diffusion pass, which does not read `ybucket`.
   */
  runTick(): void {
    const s = this.sim;

    if (this.reduce === "binned") {
      this.agentsBinned();
      this.b.wait(this.canWait);
      if (this.tid === 0) this.prefixBinned();
      this.b.wait(this.canWait);
      this.scatterBinned();
      this.b.wait(this.canWait);
      this.depositBinned();
      this.b.wait(this.canWait);
      this.mergeBinned();
      this.b.wait(this.canWait);
      if (this.tid === 0 && this.adaptive) this.rebalance();
    } else {
      this.agentsPrivate();
      this.b.wait(this.canWait);
      this.mergePrivate();
      this.b.wait(this.canWait);
    }

    const [ylo, yhi] = split(this.height, this.t, this.tid);
    s.diffuseRows(ylo, yhi);
    this.b.wait(this.canWait);

    s.swapBuffers();
  }

  private bucketOf(idx: number): number {
    return this.v.ybucket[idx >>> this.log2w];
  }

  /* ---- private ---------------------------------------------------------- */

  private agentsPrivate(): void {
    const [lo, hi] = split(this.agents, this.t, this.tid);
    const s = this.sim;
    // Point the sim's deposit target at this thread's own grid-sized buffer,
    // so `agentRange` deposits there without knowing about threads at all.
    const saved = s.dep;
    s.dep = this.v.priv.subarray(this.tid * this.cells, (this.tid + 1) * this.cells);
    s.agentRange(lo, hi, null);
    s.dep = saved;
  }

  /**
   * Fixed thread order, so the result is reproducible for this thread count.
   * It is NOT in general the same grouping as the serial chain -- SPEC-1
   * section 5.6.
   */
  private mergePrivate(): void {
    const [lo, hi] = split(this.cells, this.t, this.tid);
    const g = this.sim.grid;
    const all = this.v.priv;
    const cells = this.cells;
    const f = Math.fround;
    for (let i = lo; i < hi; i++) {
      let acc = all[i];
      all[i] = 0.0;
      for (let th = 1; th < this.t; th++) {
        acc = f(acc + all[th * cells + i]);
        all[th * cells + i] = 0.0;
      }
      g[i] = f(g[i] + acc);
    }
  }

  /* ---- binned ----------------------------------------------------------- */

  private agentsBinned(): void {
    const [lo, hi] = split(this.agents, this.t, this.tid);
    const { aidx, counts, rowcnt, ybucket } = this.v;
    const t = this.t;
    const base = this.tid * t;
    for (let b = 0; b < t; b++) counts[base + b] = 0;

    // Record the target cells; nothing is deposited yet.
    this.sim.agentRange(lo, hi, aidx);

    if (!this.adaptive) {
      for (let i = lo; i < hi; i++) counts[base + this.bucketOf(aidx[i])]++;
      return;
    }
    const h = this.height;
    const rbase = this.tid * h;
    for (let y = 0; y < h; y++) rowcnt[rbase + y] = 0;
    for (let i = lo; i < hi; i++) {
      const y = aidx[i] >>> this.log2w;
      rowcnt[rbase + y]++;
      counts[base + ybucket[y]]++;
    }
  }

  /**
   * Prefix sum over (bucket, thread) in that order, by thread 0 alone.
   * Because each thread owns a contiguous ascending agent range, walking
   * threads in order inside a bucket lays the agents down in ascending global
   * index -- which is what makes the deposit chain identical to the serial one.
   */
  private prefixBinned(): void {
    const { counts, offsets } = this.v;
    const t = this.t;
    let running = 0;
    for (let b = 0; b < t; b++) {
      for (let w = 0; w < t; w++) {
        offsets[w * t + b] = running;
        running += counts[w * t + b];
      }
    }
  }

  private scatterBinned(): void {
    const [lo, hi] = split(this.agents, this.t, this.tid);
    const { aidx, sorted, offsets } = this.v;
    const base = this.tid * this.t;
    for (let i = lo; i < hi; i++) {
      const b = base + this.bucketOf(aidx[i]);
      sorted[offsets[b]++] = i;
    }
  }

  /** Applies exactly the deposits landing in this thread's row block, in
   *  ascending agent index. Cells in other blocks are never touched. */
  private depositBinned(): void {
    const { aidx, sorted, counts } = this.v;
    const t = this.t;
    const dep = this.sim.dep!;
    const deposit = this.deposit;
    const f = Math.fround;

    let begin = 0;
    for (let b = 0; b < this.tid; b++) for (let w = 0; w < t; w++) begin += counts[w * t + b];
    let end = begin;
    for (let w = 0; w < t; w++) end += counts[w * t + this.tid];

    for (let j = begin; j < end; j++) {
      const idx = aidx[sorted[j]];
      dep[idx] = f(dep[idx] + deposit);
    }
  }

  /** Partitioned by rows rather than cells so the same pass can reduce the
   *  per-row histograms; a row range is a contiguous cell range anyway. */
  private mergeBinned(): void {
    const [ylo, yhi] = split(this.height, this.t, this.tid);
    this.sim.mergeRows(ylo, yhi);
    if (!this.adaptive) return;
    const { rowcnt, rowsum } = this.v;
    const h = this.height;
    for (let y = ylo; y < yhi; y++) {
      let sum = 0;
      for (let th = 0; th < this.t; th++) sum += rowcnt[th * h + y];
      rowsum[y] = sum;
    }
  }

  /**
   * Recompute row boundaries so every thread gets a similar number of
   * deposits. Cannot change the result: the partition decides *which* thread
   * applies a deposit, never the order deposits hit a cell.
   */
  private rebalance(): void {
    const { rowsum, ybucket } = this.v;
    const h = this.height;
    const t = this.t;
    let total = 0;
    for (let y = 0; y < h; y++) total += rowsum[y];
    if (total === 0) return;

    let b = 0;
    let acc = 0;
    for (let y = 0; y < h; y++) {
      ybucket[y] = b;
      acc += rowsum[y];
      while (b + 1 < t && acc * t >= total * (b + 1) && h - y - 1 >= t - b - 1) b++;
    }
  }
}

/** Row -> owning thread, matching the diffusion split so a thread's deposits
 *  land in rows it already touches. */
export function initYBucket(ybucket: Uint16Array, height: number, threads: number): void {
  for (let b = 0; b < threads; b++) {
    const [lo, hi] = split(height, threads, b);
    for (let y = lo; y < hi; y++) ybucket[y] = b;
  }
}
