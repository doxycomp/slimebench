//! CLI parsing and result reporting (SPEC-1 section 10).

use crate::sim::{Config, Sim, Update};

pub struct Opts {
    pub cfg: Config,
    pub want_render: bool,
    pub want_json: bool,
    pub freeze_sim: bool,
    pub dump_grid: Option<String>,
    pub display_max: f32,
}

const USAGE: &str = "\
usage: slimebench [options]   (slimebench SPEC-1)
  --preset NAME        tiny|small|medium|large|browser
  --width N --height N powers of two
  --agents N  --ticks N  --warmup N  --seed N
  --update MODE        serial|deferred
  --threads N
  --sensor-dist F  --sensor-steps N  --rot-steps N
  --step F  --deposit F  --decay F
  --headless  --render  --freeze-sim
  --simd / --no-simd   vectorised diffusion pass (class V)
  --json  --hash-every N  --dump-grid PATH  --display-max F
  -h, --help";

fn fail(msg: &str) -> ! {
    eprintln!("error: {msg}\n{USAGE}");
    std::process::exit(2);
}

fn apply_preset(c: &mut Config, name: &str) -> bool {
    let (w, h, a, t) = match name {
        "tiny" => (512u32, 512u32, 65_536u32, 1000u32),
        "small" => (1024, 1024, 262_144, 1000),
        "medium" => (2048, 2048, 1_048_576, 1000),
        "large" => (4096, 4096, 4_194_304, 500),
        "browser" => (1024, 1024, 262_144, 0),
        _ => return false,
    };
    c.width = w;
    c.height = h;
    c.agents = a;
    c.ticks = t;
    c.preset = name.to_string();
    true
}

pub fn parse_args() -> Opts {
    let argv: Vec<String> = std::env::args().collect();
    let mut o = Opts {
        cfg: Config::default(),
        want_render: false,
        want_json: false,
        freeze_sim: false,
        dump_grid: None,
        display_max: 100.0,
    };

    let mut i = 1;
    let need = |i: usize, argv: &[String], flag: &str| -> String {
        if i + 1 >= argv.len() {
            fail(&format!("{flag} requires a value"));
        }
        argv[i + 1].clone()
    };
    let u32v = |s: &str| -> u32 { s.parse().unwrap_or_else(|_| fail(&format!("'{s}' is not an integer"))) };
    let f32v = |s: &str| -> f32 { s.parse().unwrap_or_else(|_| fail(&format!("'{s}' is not a number"))) };

    while i < argv.len() {
        let a = argv[i].as_str();
        match a {
            "-h" | "--help" => {
                println!("{USAGE}");
                std::process::exit(0);
            }
            "--preset" => {
                let v = need(i, &argv, a);
                if !apply_preset(&mut o.cfg, &v) {
                    fail(&format!("unknown preset '{v}'"));
                }
                i += 1;
            }
            "--width" => { o.cfg.width = u32v(&need(i, &argv, a)); o.cfg.preset = "custom".into(); i += 1; }
            "--height" => { o.cfg.height = u32v(&need(i, &argv, a)); o.cfg.preset = "custom".into(); i += 1; }
            "--agents" => { o.cfg.agents = u32v(&need(i, &argv, a)); o.cfg.preset = "custom".into(); i += 1; }
            "--ticks" => { o.cfg.ticks = u32v(&need(i, &argv, a)); i += 1; }
            "--warmup" => { o.cfg.warmup = u32v(&need(i, &argv, a)); i += 1; }
            "--seed" => { o.cfg.seed = u32v(&need(i, &argv, a)); i += 1; }
            "--threads" => { o.cfg.threads = u32v(&need(i, &argv, a)); i += 1; }
            "--hash-every" => { o.cfg.hash_every = u32v(&need(i, &argv, a)); i += 1; }
            "--sensor-steps" => { o.cfg.sensor_steps = u32v(&need(i, &argv, a)); i += 1; }
            "--rot-steps" => { o.cfg.rot_steps = u32v(&need(i, &argv, a)); i += 1; }
            "--sensor-dist" => { o.cfg.sensor_dist = f32v(&need(i, &argv, a)); i += 1; }
            "--step" => { o.cfg.step = f32v(&need(i, &argv, a)); i += 1; }
            "--deposit" => { o.cfg.deposit = f32v(&need(i, &argv, a)); i += 1; }
            "--decay" => { o.cfg.decay = f32v(&need(i, &argv, a)); i += 1; }
            "--display-max" => { o.display_max = f32v(&need(i, &argv, a)); i += 1; }
            "--dump-grid" => { o.dump_grid = Some(need(i, &argv, a)); i += 1; }
            "--update" => {
                let m = need(i, &argv, a);
                o.cfg.update = match m.as_str() {
                    "serial" => Update::Serial,
                    "deferred" => Update::Deferred,
                    _ => fail("--update must be serial|deferred"),
                };
                i += 1;
            }
            "--simd" => o.cfg.simd = true,
            "--no-simd" => o.cfg.simd = false,
            "--headless" => o.want_render = false,
            "--render" => o.want_render = true,
            "--freeze-sim" => o.freeze_sim = true,
            "--json" => o.want_json = true,
            // SPEC-1 section 10: never silently ignore an unknown flag.
            _ => fail(&format!("unknown argument '{a}'")),
        }
        i += 1;
    }
    o
}

pub fn result_json(
    sim: &Sim,
    backend: &str,
    class: &str,
    ms_total: f64,
    tick_ms: &[f64],
) -> String {
    let mut sorted = tick_ms.to_vec();
    sorted.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let n = sorted.len();
    let median = if n > 0 { sorted[n / 2] } else { 0.0 };
    let p99 = if n > 0 {
        sorted[usize::min(n - 1, (n as f64 * 0.99) as usize)]
    } else {
        0.0
    };
    let mean = if n > 0 { tick_ms.iter().sum::<f64>() / n as f64 } else { 0.0 };

    let c = &sim.cfg;
    // One field describing what actually ran: the indexing variant, and the
    // vector ISA the diffusion pass was compiled for.
    let variant = if c.simd {
        format!("{}+simd-{}", Sim::variant(), crate::simd::simd_name())
    } else {
        Sim::variant().to_string()
    };
    let cells = c.width as f64 * c.height as f64;
    let maups = if ms_total > 0.0 { c.agents as f64 * n as f64 / ms_total / 1000.0 } else { 0.0 };
    let mcups = if ms_total > 0.0 { cells * n as f64 / ms_total / 1000.0 } else { 0.0 };

    format!(
        concat!(
            r#"{{"schema":1,"impl":"rust","backend":"{}","class":"{}","preset":"{}","#,
            r#""variant":"{}","width":{},"height":{},"agents":{},"ticks":{},"seed":{},"#,
            r#""update":"{}","threads":{},"#,
            r#""grid_hash":"0x{:08X}","agent_hash":"0x{:08X}","dirtable_hash":"0x{:08X}","#,
            r#""ms_total":{:.4},"ms_agents":{:.4},"ms_diffuse":{:.4},"#,
            r#""ms_per_tick_mean":{:.6},"ms_per_tick_median":{:.6},"ms_per_tick_p99":{:.6},"#,
            r#""maups":{:.4},"mcups":{:.4}}}"#
        ),
        backend,
        class,
        c.preset,
        &variant,
        c.width,
        c.height,
        c.agents,
        n,
        c.seed,
        if c.update == Update::Deferred { "deferred" } else { "serial" },
        c.threads,
        sim.hash_grid(),
        sim.hash_agents(),
        Sim::dirtable_hash(),
        ms_total,
        sim.ns_agents as f64 / 1e6,
        sim.ns_diffuse as f64 / 1e6,
        mean,
        median,
        p99,
        maups,
        mcups
    )
}
