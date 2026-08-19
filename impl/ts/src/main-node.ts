/** slimebench -- TypeScript headless benchmark (Node, classes S and P). */

import { writeFileSync } from "node:fs";
import { Sim, hex32, nowNs } from "./sim.ts";
import { parseArgs, resultJson } from "./cli.ts";
import { runParallel } from "./pool-node.ts";

const p = parseArgs(process.argv.slice(2));

let sim: Sim;
let msTotal: number;
let tickMs: number[];

if (p.threads > 1) {
  ({ sim, msTotal, tickMs } = await runParallel(p));
} else {
  sim = new Sim(p.cfg);

  for (let t = 0; t < p.warmup; t++) sim.tick();
  sim.nsAgents = 0;
  sim.nsDiffuse = 0;

  tickMs = [];
  const tStart = nowNs();
  for (let t = 0; t < p.ticks; t++) {
    const a = nowNs();
    sim.tick();
    tickMs.push((nowNs() - a) / 1e6);

    if (p.hashEvery && (t + 1) % p.hashEvery === 0) {
      process.stderr.write(
        `tick ${t + 1} grid=${hex32(sim.hashGrid())} agents=${hex32(sim.hashAgents())}\n`,
      );
    }
  }
  msTotal = (nowNs() - tStart) / 1e6;
}

if (p.dumpGrid) {
  writeFileSync(p.dumpGrid, Buffer.from(sim.grid.buffer, sim.grid.byteOffset, sim.grid.byteLength));
}

if (p.json) {
  console.log(resultJson(sim, p, "ts", p.threads > 1 ? "worker" : "headless",
                         p.threads > 1 ? "P" : "S", msTotal, tickMs));
} else {
  console.log(`${p.preset} ${sim.cfg.width}x${sim.cfg.height} agents=${sim.cfg.agents} ticks=${p.ticks} update=${sim.cfg.update}${p.threads > 1 ? ` threads=${p.threads} reduce=${p.reduce}` : ""}`);
  console.log(`  grid_hash  ${hex32(sim.hashGrid())}`);
  console.log(`  agent_hash ${hex32(sim.hashAgents())}`);
  console.log(`  total      ${msTotal.toFixed(2)} ms  (${(msTotal / Math.max(1, p.ticks)).toFixed(4)} ms/tick)`);
  console.log(`  agents     ${(sim.nsAgents / 1e6).toFixed(2)} ms`);
  console.log(`  diffuse    ${(sim.nsDiffuse / 1e6).toFixed(2)} ms`);
}
