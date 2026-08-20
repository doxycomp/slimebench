/**
 * slimebench -- browser frontend on an HTML5 canvas.
 *
 * Rendering strategy (the only one that is fast enough): the simulation never
 * touches a canvas drawing call. It writes bytes into the Uint8ClampedArray
 * behind a single ImageData object and hands the whole block to the GPU with
 * one putImageData per frame. Zero per-agent draw calls.
 *
 * The simulation core is the exact same module the Node benchmark uses, so
 * whatever you tune here is reproducible in every other implementation.
 */

import { Sim, PRESETS, defaultConfig, hex32, type SimConfig } from "./sim.ts";

const canvas = document.getElementById("view") as HTMLCanvasElement;
const ctx = canvas.getContext("2d", { alpha: false })!;

let sim: Sim;
let image: ImageData;
let running = true;
let ticksPerFrame = 1;
let tickCount = 0;

/* ---- controls ----------------------------------------------------------- */

interface Control {
  id: string;
  label: string;
  min: number;
  max: number;
  stepSize: number;
  get: (c: SimConfig) => number;
  set: (c: SimConfig, v: number) => void;
  /** Changing this needs a full re-init (buffer sizes / agent count). */
  reinit?: boolean;
  fmt?: (v: number) => string;
}

const CONTROLS: Control[] = [
  { id: "sensorDist",  label: "Sensor-Distanz", min: 1, max: 40, stepSize: 0.5,
    get: c => c.sensorDist, set: (c, v) => (c.sensorDist = Math.fround(v)) },
  { id: "sensorSteps", label: "Sensor-Winkel",  min: 4, max: 360, stepSize: 4,
    get: c => c.sensorSteps, set: (c, v) => (c.sensorSteps = v | 0),
    fmt: v => `${((v / 1440) * 360).toFixed(1)}°` },
  { id: "rotSteps",    label: "Rotation",       min: 4, max: 360, stepSize: 4,
    get: c => c.rotSteps, set: (c, v) => (c.rotSteps = v | 0),
    fmt: v => `${((v / 1440) * 360).toFixed(1)}°` },
  { id: "step",        label: "Schrittweite",   min: 0.1, max: 5, stepSize: 0.1,
    get: c => c.step, set: (c, v) => (c.step = Math.fround(v)) },
  { id: "deposit",     label: "Deposit",        min: 0.5, max: 50, stepSize: 0.5,
    get: c => c.deposit, set: (c, v) => (c.deposit = Math.fround(v)) },
  { id: "decay",       label: "Decay",          min: 0.5, max: 0.999, stepSize: 0.002,
    get: c => c.decay, set: (c, v) => (c.decay = Math.fround(v)) },
  { id: "agents",      label: "Agenten",        min: 1024, max: 1048576, stepSize: 1024,
    get: c => c.agents, set: (c, v) => (c.agents = v | 0), reinit: true,
    fmt: v => v >= 1024 ? `${Math.round(v / 1024)}k` : `${v}` },
];

let cfg: SimConfig = { ...defaultConfig(), ...PRESETS.browser, update: "serial" };

function rebuild(): void {
  sim = new Sim({ ...cfg });
  canvas.width = cfg.width;
  canvas.height = cfg.height;
  image = ctx.createImageData(cfg.width, cfg.height);
  tickCount = 0;
}

/** Apply live parameter edits without discarding the current pheromone field. */
function applyLive(): void {
  sim.cfg.sensorDist = cfg.sensorDist;
  sim.cfg.sensorSteps = cfg.sensorSteps;
  sim.cfg.rotSteps = cfg.rotSteps;
  sim.cfg.step = cfg.step;
  sim.cfg.deposit = cfg.deposit;
  sim.cfg.decay = cfg.decay;
}

function buildUI(): void {
  const panel = document.getElementById("controls")!;

  for (const c of CONTROLS) {
    const row = document.createElement("label");
    row.className = "row";

    const name = document.createElement("span");
    name.className = "name";
    name.textContent = c.label;

    const input = document.createElement("input");
    // Read back by the keyboard bindings, which drive the slider rather than
    // the config so both routes share one handler.
    input.dataset.id = c.id;
    input.type = "range";
    input.min = String(c.min);
    input.max = String(c.max);
    input.step = String(c.stepSize);
    input.value = String(c.get(cfg));

    const out = document.createElement("span");
    out.className = "val";
    const show = () => {
      const v = c.get(cfg);
      out.textContent = c.fmt ? c.fmt(v) : String(Math.round(v * 1000) / 1000);
    };
    show();

    input.addEventListener("input", () => {
      c.set(cfg, Number(input.value));
      show();
      if (c.reinit) rebuild();
      else applyLive();
    });

    row.append(name, input, out);
    panel.append(row);
  }

  const speed = document.getElementById("speed") as HTMLInputElement;
  speed.addEventListener("input", () => {
    ticksPerFrame = Number(speed.value);
    document.getElementById("speedVal")!.textContent = `${ticksPerFrame}x`;
  });

  document.getElementById("pause")!.addEventListener("click", (e) => {
    running = !running;
    (e.target as HTMLButtonElement).textContent = running ? "Pause" : "Weiter";
  });
  document.getElementById("reset")!.addEventListener("click", () => rebuild());
  document.getElementById("reseed")!.addEventListener("click", () => {
    cfg.seed = (Math.random() * 0xffffffff) >>> 0;
    rebuild();
  });
}

/* ---- main loop ---------------------------------------------------------- */

let frames = 0;
let fpsT0 = performance.now();
const displayMax = 100.0;

function frame(): void {
  if (running) {
    for (let i = 0; i < ticksPerFrame; i++) {
      sim.tick();
      tickCount++;
    }
  }

  sim.renderRGBA(image.data, displayMax);
  ctx.putImageData(image, 0, 0);

  if (++frames >= 30) {
    const now = performance.now();
    const fps = (frames * 1000) / (now - fpsT0);
    const mtps = (fps * ticksPerFrame * cfg.agents) / 1e6;
    document.getElementById("stats")!.textContent =
      `${fps.toFixed(1)} fps  ·  ${mtps.toFixed(1)} M Agent-Updates/s  ·  Tick ${tickCount}`;
    frames = 0;
    fpsT0 = now;
  }

  requestAnimationFrame(frame);
}

function showHash(): void {
  document.getElementById("hash")!.textContent =
    `Tick ${tickCount}  grid=${hex32(sim.hashGrid())}  agents=${hex32(sim.hashAgents())}`;
}

document.getElementById("hashBtn")!.addEventListener("click", showHash);

/* ---- keyboard ------------------------------------------------------------
 *
 * The same key map the native frontends use (impl/c/sb_hud.h), so muscle
 * memory carries across all seven. No bitmap overlay here: this page has a
 * DOM, and drawing text into the canvas with a 5x7 font when the sidebar can
 * render it properly would be a worse HUD, not a more consistent one. What
 * has to be consistent is which key does what.
 *
 * Parameters sit on digit pairs rather than letter-plus-shift because SDL2,
 * raylib, GLFW and the browser each report shift state differently -- here it
 * would be easy, but a scheme that only works in one frontend is the thing
 * being avoided.
 */

function setPauseLabel(): void {
  document.getElementById("pause")!.textContent = running ? "Pause" : "Weiter";
}

/** Nudge a slider by n steps and fire its input handler, so the keyboard and
 * the mouse go through exactly one code path. */
function nudge(id: string, n: number): void {
  const input = document.querySelector<HTMLInputElement>(`#controls input[data-id="${id}"]`);
  if (!input) return;
  const step = Number(input.step) || 1;
  const v = Number(input.value) + n * step;
  input.value = String(Math.min(Number(input.max), Math.max(Number(input.min), v)));
  input.dispatchEvent(new Event("input", { bubbles: true }));
}

function toggleHelp(force?: boolean): void {
  const el = document.getElementById("help")!;
  const show = force ?? el.hidden;
  el.hidden = !show;
}

const KEYS: Record<string, () => void> = {
  " ": () => { running = !running; setPauseLabel(); },
  n: () => { running = false; setPauseLabel(); sim.tick(); tickCount++; },
  r: () => rebuild(),
  c: () => showHash(),
  h: () => toggleHelp(),
  F1: () => toggleHelp(),
  Escape: () => toggleHelp(false),
  "1": () => nudge("deposit", -1),
  "2": () => nudge("deposit", +1),
  "3": () => nudge("decay", -1),
  "4": () => nudge("decay", +1),
  "5": () => nudge("sensorDist", -1),
  "6": () => nudge("sensorDist", +1),
  "7": () => nudge("step", -1),
  "8": () => nudge("step", +1),
  "9": () => nudge("rotSteps", -1),
  "0": () => nudge("rotSteps", +1),
};

window.addEventListener("keydown", (e) => {
  // A slider has focus after it is dragged, and the arrow keys belong to it.
  const t = e.target as HTMLElement | null;
  if (t && (t.tagName === "INPUT" || t.tagName === "TEXTAREA")) return;
  if (e.ctrlKey || e.metaKey || e.altKey) return;
  const fn = KEYS[e.key] ?? KEYS[e.key.toLowerCase()];
  if (!fn) return;
  e.preventDefault();
  fn();
});

buildUI();
rebuild();
requestAnimationFrame(frame);

/**
 * Console handle. `slimebench.step(200)` advances and repaints without waiting
 * for animation frames -- handy for poking at parameters, and the only way to
 * drive the page when the tab is backgrounded (rAF is paused there).
 */
(globalThis as Record<string, unknown>).slimebench = {
  get sim() { return sim; },
  get cfg() { return cfg; },
  step(n = 1) {
    for (let i = 0; i < n; i++) { sim.tick(); tickCount++; }
    sim.renderRGBA(image.data, displayMax);
    ctx.putImageData(image, 0, 0);
    return { tick: tickCount, grid: hex32(sim.hashGrid()), agents: hex32(sim.hashAgents()) };
  },
  rebuild,
};
