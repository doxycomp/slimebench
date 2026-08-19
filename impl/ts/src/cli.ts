/** Shared CLI parsing / result reporting for the TS targets (SPEC-1 §10). */

// Node's type stripping erases `import type` but cannot know that `SimConfig`
// is type-only in a value import -- so types get their own statement.
import type { SimConfig, Sim, UpdateMode } from "./sim.ts";
import { PRESETS, defaultConfig, dirtableHash, hex32 } from "./sim.ts";

export interface Parsed {
  cfg: SimConfig;
  ticks: number;
  warmup: number;
  preset: string;
  json: boolean;
  render: boolean;
  hashEvery: number;
  dumpGrid: string | null;
  displayMax: number;
  threads: number;
  reduce: "private" | "binned";
}

const USAGE = `usage: slimebench-ts [options]
  --preset NAME        tiny|small|medium|large|browser
  --width N --height N powers of two
  --agents N  --ticks N  --warmup N  --seed N
  --update MODE        serial|deferred
  --threads N
  --deposit-reduce M   private|binned  (SPEC-1 5.6)
  --sensor-dist F  --sensor-steps N  --rot-steps N
  --step F  --deposit F  --decay F
  --headless  --render
  --json  --hash-every N  --dump-grid PATH  --display-max F
  -h, --help`;

export function parseArgs(argv: string[]): Parsed {
  const p: Parsed = {
    cfg: defaultConfig(),
    ticks: 1000,
    warmup: 0,
    preset: "custom",
    json: false,
    render: false,
    hashEvery: 0,
    dumpGrid: null,
    displayMax: 100.0,
    threads: 1,
    reduce: "binned",
  };

  const need = (i: number, flag: string): string => {
    if (i + 1 >= argv.length) fail(`${flag} requires a value`);
    return argv[i + 1];
  };

  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    switch (a) {
      case "-h": case "--help": console.log(USAGE); process.exit(0); break;
      case "--preset": {
        const name = need(i++, a);
        const pr = PRESETS[name];
        if (!pr) fail(`unknown preset '${name}'`);
        p.cfg.width = pr.width; p.cfg.height = pr.height;
        p.cfg.agents = pr.agents; p.ticks = pr.ticks; p.preset = name;
        break;
      }
      case "--width":         p.cfg.width  = int(need(i++, a)); p.preset = "custom"; break;
      case "--height":        p.cfg.height = int(need(i++, a)); p.preset = "custom"; break;
      case "--agents":        p.cfg.agents = int(need(i++, a)); p.preset = "custom"; break;
      case "--ticks":         p.ticks = int(need(i++, a)); break;
      case "--warmup":        p.warmup = int(need(i++, a)); break;
      case "--seed":          p.cfg.seed = int(need(i++, a)) >>> 0; break;
      case "--threads":       p.threads = int(need(i++, a)); break;
      case "--hash-every":    p.hashEvery = int(need(i++, a)); break;
      case "--sensor-steps":  p.cfg.sensorSteps = int(need(i++, a)); break;
      case "--rot-steps":     p.cfg.rotSteps = int(need(i++, a)); break;
      case "--sensor-dist":   p.cfg.sensorDist = Math.fround(num(need(i++, a))); break;
      case "--step":          p.cfg.step = Math.fround(num(need(i++, a))); break;
      case "--deposit":       p.cfg.deposit = Math.fround(num(need(i++, a))); break;
      case "--decay":         p.cfg.decay = Math.fround(num(need(i++, a))); break;
      case "--display-max":   p.displayMax = num(need(i++, a)); break;
      case "--dump-grid":     p.dumpGrid = need(i++, a); break;
      case "--update": {
        const m = need(i++, a);
        if (m !== "serial" && m !== "deferred") fail("--update must be serial|deferred");
        p.cfg.update = m as UpdateMode;
        break;
      }
      case "--deposit-reduce": {
        const m = need(i++, a);
        if (m !== "private" && m !== "binned") fail("--deposit-reduce must be private|binned");
        p.reduce = m;
        break;
      }
      case "--headless": p.render = false; break;
      case "--render":   p.render = true;  break;
      case "--json":     p.json = true;    break;
      default:
        // SPEC-1 §10: never silently ignore an unknown flag.
        fail(`unknown argument '${a}'`);
    }
  }
  return p;
}

function fail(msg: string): never {
  process.stderr.write(`error: ${msg}\n${USAGE}\n`);
  process.exit(2);
}

function int(s: string): number {
  const v = Number.parseInt(s, 10);
  if (!Number.isFinite(v)) fail(`'${s}' is not an integer`);
  return v;
}

function num(s: string): number {
  const v = Number.parseFloat(s);
  if (!Number.isFinite(v)) fail(`'${s}' is not a number`);
  return v;
}

export function resultJson(
  sim: Sim, p: Parsed, impl: string, backend: string, cls: string,
  msTotal: number, tickMs: number[],
): string {
  const sorted = [...tickMs].sort((a, b) => a - b);
  const n = sorted.length;
  const median = n ? sorted[n >> 1] : 0;
  const p99 = n ? sorted[Math.min(n - 1, Math.floor(n * 0.99))] : 0;
  const mean = n ? tickMs.reduce((a, b) => a + b, 0) / n : 0;

  const cells = sim.cfg.width * sim.cfg.height;
  const maups = msTotal > 0 ? (sim.cfg.agents * n) / msTotal / 1000 : 0;
  const mcups = msTotal > 0 ? (cells * n) / msTotal / 1000 : 0;

  return JSON.stringify({
    schema: 1,
    impl, backend, class: cls, preset: p.preset,
    width: sim.cfg.width, height: sim.cfg.height, agents: sim.cfg.agents,
    ticks: n, seed: sim.cfg.seed, update: sim.cfg.update, threads: p.threads,
    variant: p.threads > 1 ? p.reduce : "scalar",
    grid_hash: hex32(sim.hashGrid()),
    agent_hash: hex32(sim.hashAgents()),
    dirtable_hash: hex32(dirtableHash()),
    ms_total: round(msTotal, 4),
    ms_agents: round(sim.nsAgents / 1e6, 4),
    ms_diffuse: round(sim.nsDiffuse / 1e6, 4),
    ms_per_tick_mean: round(mean, 6),
    ms_per_tick_median: round(median, 6),
    ms_per_tick_p99: round(p99, 6),
    maups: round(maups, 4),
    mcups: round(mcups, 4),
  });
}

function round(v: number, digits: number): number {
  const m = 10 ** digits;
  return Math.round(v * m) / m;
}
