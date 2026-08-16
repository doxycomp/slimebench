/**
 * slimebench -- TypeScript implementation of SPEC-1.
 *
 * Shared by the Node headless benchmark and the browser canvas frontend.
 * No DOM, no Node API in this file.
 *
 * ## Why Math.fround() is everywhere
 *
 * JavaScript has no f32 arithmetic: `a + b` on two values read out of a
 * Float32Array is computed in f64. SPEC-1 section 1.2 requires every single
 * operation to round to f32.
 *
 * Math.fround(f64_op(a, b)) is provably identical to the f32 operation for
 * +, -, * and /: double rounding is harmless when the intermediate format has
 * at least 2*p + 2 bits, and 53 >= 2*24 + 2. So this file is bit-exact with
 * the C reference, not merely close to it.
 */

import { COS, SIN, NDIR } from "./dirtable.ts";

const f = Math.fround;

export const SPEC_VERSION = "SPEC-1";

export type UpdateMode = "serial" | "deferred";

export interface SimConfig {
  width: number;
  height: number;
  agents: number;
  seed: number;
  update: UpdateMode;
  sensorDist: number;
  step: number;
  deposit: number;
  decay: number;
  sensorSteps: number;
  rotSteps: number;
}

export const PRESETS: Record<string, { width: number; height: number; agents: number; ticks: number }> = {
  tiny:    { width: 512,  height: 512,  agents: 65536,   ticks: 1000 },
  small:   { width: 1024, height: 1024, agents: 262144,  ticks: 1000 },
  medium:  { width: 2048, height: 2048, agents: 1048576, ticks: 1000 },
  large:   { width: 4096, height: 4096, agents: 4194304, ticks: 500 },
  browser: { width: 1024, height: 1024, agents: 262144,  ticks: 0 },
};

export function defaultConfig(): SimConfig {
  return normalizeConfig({
    width: 1024, height: 1024, agents: 262144, seed: 12345,
    update: "serial",
    sensorDist: 9.0, step: 1.0, deposit: 10.0, decay: 0.94,
    sensorSteps: 144, rotSteps: 144,
  });
}

/**
 * Force every f32 parameter through Math.fround.
 *
 * This is not cosmetic. A JS numeric literal is f64: `0.94` and C's `0.94f`
 * are different numbers, and multiplying the whole grid by the wrong one every
 * tick drifts the two implementations apart by a few ULP -- enough to break
 * bit-exact conformance while still looking perfectly correct on screen.
 * 9.0, 1.0 and 10.0 happen to be exact in f32, so `decay` was the only
 * parameter that actually bit us. Normalise all of them anyway.
 */
export function normalizeConfig(c: SimConfig): SimConfig {
  c.sensorDist = f(c.sensorDist);
  c.step = f(c.step);
  c.deposit = f(c.deposit);
  c.decay = f(c.decay);
  return c;
}

/* ---- PRNG (SPEC-1 section 3.1) ------------------------------------------ */

function rotl32(x: number, k: number): number {
  return ((x << k) | (x >>> (32 - k))) >>> 0;
}

/** SplitMix32 over a 1-element Uint32Array used as a mutable reference. */
function splitmix32(st: Uint32Array): number {
  st[0] = (st[0] + 0x9e3779b9) >>> 0;
  let z = st[0];
  z = Math.imul(z ^ (z >>> 16), 0x21f0aaad) >>> 0;
  z = Math.imul(z ^ (z >>> 15), 0x735a2d97) >>> 0;
  return (z ^ (z >>> 15)) >>> 0;
}

/** xoshiro128++ over `s[o..o+3]`. */
function xoshiro128pp(s: Uint32Array, o: number): number {
  const result = (rotl32((s[o] + s[o + 3]) >>> 0, 7) + s[o]) >>> 0;
  const t = (s[o + 1] << 9) >>> 0;
  s[o + 2] ^= s[o];
  s[o + 3] ^= s[o + 1];
  s[o + 1] ^= s[o + 2];
  s[o] ^= s[o + 3];
  s[o + 2] ^= t;
  s[o + 3] = rotl32(s[o + 3], 11);
  return result;
}

/** SPEC-1 section 3.2. */
function rnd01(u: number): number {
  return f((u >>> 8) / 16777216.0);
}

/* ---- checksums (SPEC-1 section 6) --------------------------------------- */

const FNV_OFFSET = 0x811c9dc5;
const FNV_PRIME = 0x01000193;

function fnvStep(h: number, w: number): number {
  return Math.imul(h ^ w, FNV_PRIME) >>> 0;
}

/* ---- simulation --------------------------------------------------------- */

export class Sim {
  readonly cfg: SimConfig;
  readonly log2w: number;
  readonly xmask: number;
  readonly ymask: number;

  grid: Float32Array;
  scratch: Float32Array;
  dep: Float32Array | null;

  readonly ax: Float32Array;
  readonly ay: Float32Array;
  readonly adir: Uint16Array;
  readonly arng: Uint32Array;

  nsAgents = 0;
  nsDiffuse = 0;

  constructor(cfg: SimConfig) {
    if (cfg.width <= 0 || (cfg.width & (cfg.width - 1)) !== 0) {
      throw new Error("width must be a power of two");
    }
    if (cfg.height <= 0 || (cfg.height & (cfg.height - 1)) !== 0) {
      throw new Error("height must be a power of two");
    }
    this.cfg = normalizeConfig(cfg);
    this.log2w = Math.log2(cfg.width) | 0;
    this.xmask = cfg.width - 1;
    this.ymask = cfg.height - 1;

    const cells = cfg.width * cfg.height;
    this.grid = new Float32Array(cells);
    this.scratch = new Float32Array(cells);
    this.dep = cfg.update === "deferred" ? new Float32Array(cells) : null;

    this.ax = new Float32Array(cfg.agents);
    this.ay = new Float32Array(cfg.agents);
    this.adir = new Uint16Array(cfg.agents);
    this.arng = new Uint32Array(cfg.agents * 4);

    this.init();
  }

  /** SPEC-1 section 3.3. */
  private init(): void {
    const { seed, width, height, agents } = this.cfg;

    const st = new Uint32Array(1);
    st[0] = (seed ^ 0x5bf03635) >>> 0;
    for (let i = 0; i < this.grid.length; i++) {
      this.grid[i] = f(rnd01(splitmix32(st)) * 100.0);
    }

    const fw = f(width);
    const fh = f(height);
    for (let i = 0; i < agents; i++) {
      st[0] = (seed + Math.imul(0x9e3779b9, i + 1)) >>> 0;
      const o = i * 4;
      this.arng[o] = splitmix32(st);
      this.arng[o + 1] = splitmix32(st);
      this.arng[o + 2] = splitmix32(st);
      this.arng[o + 3] = splitmix32(st);
      if ((this.arng[o] | this.arng[o + 1] | this.arng[o + 2] | this.arng[o + 3]) === 0) {
        this.arng[o] = 1;
      }
      this.ax[i] = f(rnd01(xoshiro128pp(this.arng, o)) * fw);
      this.ay[i] = f(rnd01(xoshiro128pp(this.arng, o)) * fh);
      this.adir[i] = xoshiro128pp(this.arng, o) % NDIR;
    }
  }

  /** SPEC-1 section 5.2. */
  tick(): void {
    const t0 = nowNs();
    this.agentPass();
    const t1 = nowNs();

    if (this.dep !== null) {
      const g = this.grid;
      const d = this.dep;
      for (let i = 0; i < g.length; i++) {
        g[i] = f(g[i] + d[i]);
        d[i] = 0.0;
      }
    }

    this.diffusePass();
    const t2 = nowNs();

    this.nsAgents += t1 - t0;
    this.nsDiffuse += t2 - t1;
  }

  /** SPEC-1 section 5.3. */
  private agentPass(): void {
    const c = this.cfg;
    const grid = this.grid;
    const target = this.dep !== null ? this.dep : this.grid;
    const { ax, ay, adir, arng, xmask, ymask, log2w } = this;
    const fw = f(c.width);
    const fh = f(c.height);
    const sdist = c.sensorDist;
    const step = c.step;
    const deposit = c.deposit;
    const ss = c.sensorSteps | 0;
    const rs = c.rotSteps | 0;
    const n = c.agents;

    for (let i = 0; i < n; i++) {
      let d = adir[i];
      let x = ax[i];
      let y = ay[i];

      const dl = (d - ss + NDIR) % NDIR;
      const dr = (d + ss) % NDIR;

      // sense(): inlined three times. Extracting it into a method costs ~15%
      // in V8 here because the closure over `this` defeats the load hoisting.
      let sx = f(x + f(COS[dl] * sdist));
      if (sx < 0) sx = f(sx + fw);
      if (sx >= fw) sx = f(sx - fw);
      let sy = f(y + f(SIN[dl] * sdist));
      if (sy < 0) sy = f(sy + fh);
      if (sy >= fh) sy = f(sy - fh);
      const fl = grid[(((sy | 0) & ymask) << log2w) | ((sx | 0) & xmask)];

      sx = f(x + f(COS[d] * sdist));
      if (sx < 0) sx = f(sx + fw);
      if (sx >= fw) sx = f(sx - fw);
      sy = f(y + f(SIN[d] * sdist));
      if (sy < 0) sy = f(sy + fh);
      if (sy >= fh) sy = f(sy - fh);
      const fc = grid[(((sy | 0) & ymask) << log2w) | ((sx | 0) & xmask)];

      sx = f(x + f(COS[dr] * sdist));
      if (sx < 0) sx = f(sx + fw);
      if (sx >= fw) sx = f(sx - fw);
      sy = f(y + f(SIN[dr] * sdist));
      if (sy < 0) sy = f(sy + fh);
      if (sy >= fh) sy = f(sy - fh);
      const fr = grid[(((sy | 0) & ymask) << log2w) | ((sx | 0) & xmask)];

      if (fc >= fl && fc >= fr) {
        // straight on
      } else if (fc < fl && fc < fr) {
        if (xoshiro128pp(arng, i * 4) & 1) d = (d + rs) % NDIR;
        else d = (d - rs + NDIR) % NDIR;
      } else if (fl > fr) {
        d = (d - rs + NDIR) % NDIR;
      } else {
        d = (d + rs) % NDIR;
      }

      x = f(x + f(COS[d] * step));
      if (x < 0) x = f(x + fw);
      if (x >= fw) x = f(x - fw);
      y = f(y + f(SIN[d] * step));
      if (y < 0) y = f(y + fh);
      if (y >= fh) y = f(y - fh);

      const idx = (((y | 0) & ymask) << log2w) | ((x | 0) & xmask);
      target[idx] = f(target[idx] + deposit);

      adir[i] = d;
      ax[i] = x;
      ay[i] = y;
    }
  }

  /** SPEC-1 section 5.4. Summation order is normative -- do not reorder. */
  private diffusePass(): void {
    const { width: w, height: h, decay } = this.cfg;
    const { xmask, ymask, log2w } = this;
    const src = this.grid;
    const dst = this.scratch;

    for (let y = 0; y < h; y++) {
      const rowm = ((y - 1) & ymask) << log2w;
      const row0 = y << log2w;
      const rowp = ((y + 1) & ymask) << log2w;

      for (let x = 0; x < w; x++) {
        const xm = (x - 1) & xmask;
        const xp = (x + 1) & xmask;

        let acc = src[rowm | xm];
        acc = f(acc + src[rowm | x]);
        acc = f(acc + src[rowm | xp]);
        acc = f(acc + src[row0 | xm]);
        acc = f(acc + f(4.0 * src[row0 | x]));
        acc = f(acc + src[row0 | xp]);
        acc = f(acc + src[rowp | xm]);
        acc = f(acc + src[rowp | x]);
        acc = f(acc + src[rowp | xp]);

        dst[row0 | x] = f(f(acc / 12.0) * decay);
      }
    }

    this.grid = dst;
    this.scratch = src;
  }

  /* ---- checksums -------------------------------------------------------- */

  hashGrid(): number {
    const words = new Uint32Array(this.grid.buffer, this.grid.byteOffset, this.grid.length);
    let hsh = FNV_OFFSET;
    for (let i = 0; i < words.length; i++) hsh = fnvStep(hsh, words[i]);
    return hsh >>> 0;
  }

  hashAgents(): number {
    const bx = new Uint32Array(this.ax.buffer, this.ax.byteOffset, this.ax.length);
    const by = new Uint32Array(this.ay.buffer, this.ay.byteOffset, this.ay.length);
    let hsh = FNV_OFFSET;
    for (let i = 0; i < this.cfg.agents; i++) {
      hsh = fnvStep(hsh, bx[i]);
      hsh = fnvStep(hsh, by[i]);
      hsh = fnvStep(hsh, this.adir[i]);
    }
    return hsh >>> 0;
  }

  /** SPEC-1 section 11: greyscale into an RGBA byte buffer. */
  renderRGBA(out: Uint8ClampedArray, displayMax: number): void {
    const g = this.grid;
    const scale = 255.0 / displayMax;
    for (let i = 0, p = 0; i < g.length; i++, p += 4) {
      let v = (g[i] * scale) | 0;
      if (v < 0) v = 0;
      else if (v > 255) v = 255;
      out[p] = v;
      out[p + 1] = v;
      out[p + 2] = v;
      out[p + 3] = 255;
    }
  }
}

export function dirtableHash(): number {
  const cb = new Uint32Array(COS.buffer, COS.byteOffset, COS.length);
  const sb = new Uint32Array(SIN.buffer, SIN.byteOffset, SIN.length);
  let hsh = FNV_OFFSET;
  for (let i = 0; i < cb.length; i++) hsh = fnvStep(hsh, cb[i]);
  for (let i = 0; i < sb.length; i++) hsh = fnvStep(hsh, sb[i]);
  return hsh >>> 0;
}

export function hex32(v: number): string {
  return "0x" + (v >>> 0).toString(16).toUpperCase().padStart(8, "0");
}

/** Monotonic nanoseconds; works in Node and in the browser. */
export const nowNs: () => number =
  typeof process !== "undefined" && typeof process.hrtime?.bigint === "function"
    ? () => Number(process.hrtime.bigint())
    : () => performance.now() * 1e6;
