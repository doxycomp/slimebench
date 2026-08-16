//! slimebench -- Rust headless benchmark (class S).

mod cli;
mod dirtable;
mod sim;

use sim::{now_ns, Sim, Update};
use std::io::Write;

fn main() {
    let o = cli::parse_args();
    let cfg = o.cfg.clone();

    let mut sim = match Sim::new(cfg.clone()) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("error: {e}");
            std::process::exit(1);
        }
    };

    for _ in 0..cfg.warmup {
        sim.tick();
    }
    sim.ns_agents = 0;
    sim.ns_diffuse = 0;

    let mut tick_ms: Vec<f64> = Vec::with_capacity(cfg.ticks as usize);
    let t_start = now_ns();
    for t in 0..cfg.ticks {
        let a = now_ns();
        sim.tick();
        tick_ms.push((now_ns() - a) as f64 / 1e6);

        if cfg.hash_every != 0 && (t + 1) % cfg.hash_every == 0 {
            eprintln!(
                "tick {} grid=0x{:08X} agents=0x{:08X}",
                t + 1,
                sim.hash_grid(),
                sim.hash_agents()
            );
        }
    }
    let ms_total = (now_ns() - t_start) as f64 / 1e6;

    if let Some(path) = &o.dump_grid {
        let bytes: Vec<u8> = sim.grid.iter().flat_map(|v| v.to_le_bytes()).collect();
        if let Err(e) = std::fs::write(path, &bytes) {
            eprintln!("error: could not write {path}: {e}");
        }
    }

    if o.want_json {
        let mut out = std::io::stdout().lock();
        let _ = writeln!(out, "{}", cli::result_json(&sim, "headless", "S", ms_total, &tick_ms));
    } else {
        println!(
            "{} {}x{} agents={} ticks={} update={} variant={}",
            cfg.preset,
            cfg.width,
            cfg.height,
            cfg.agents,
            cfg.ticks,
            if cfg.update == Update::Deferred { "deferred" } else { "serial" },
            Sim::variant()
        );
        println!("  grid_hash  0x{:08X}", sim.hash_grid());
        println!("  agent_hash 0x{:08X}", sim.hash_agents());
        println!(
            "  total      {:.2} ms  ({:.4} ms/tick)",
            ms_total,
            if cfg.ticks > 0 { ms_total / cfg.ticks as f64 } else { 0.0 }
        );
        println!("  agents     {:.2} ms", sim.ns_agents as f64 / 1e6);
        println!("  diffuse    {:.2} ms", sim.ns_diffuse as f64 / 1e6);
    }
}
