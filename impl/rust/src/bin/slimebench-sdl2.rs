//! slimebench -- Rust + SDL2 frontend (benchmark class R).
//!
//! Same work as the raylib frontend on the identical byte buffer. The one
//! substantive difference is the pixel format: SDL2 has no 8-bit greyscale
//! texture, so the buffer has to be expanded to ARGB8888 every frame, while
//! raylib takes the greyscale buffer directly. That asymmetry is left in
//! rather than equalised -- it is how you would actually write each one, and
//! in C it turned out to be most of the difference between them.

// Each frontend includes the whole simulation via #[path]; the parts this
// binary does not call are not dead code, they just belong to another one.
#![allow(dead_code)]

use sdl2::event::Event;
use sdl2::keyboard::Keycode;
use sdl2::pixels::PixelFormatEnum;

#[path = "../cli.rs"]
mod cli;
#[path = "../dirtable.rs"]
mod dirtable;
#[path = "../hud.rs"]
mod hud;
#[path = "../parallel.rs"]
mod parallel;
#[path = "../render.rs"]
mod render;
#[path = "../simd.rs"]
mod simd;
#[path = "../sim.rs"]
mod sim;

use hud::{Action, Hud};
use render::RenderStats;
use sim::{now_ns, Sim};

/// SDL keycodes for printable ASCII are the ASCII value, so the shared table
/// covers everything except the three keys that have no character.
fn sdl_action(k: Keycode) -> Action {
    match k {
        Keycode::Escape => Action::Quit,
        Keycode::Tab => Action::Hud,
        Keycode::F1 => Action::Help,
        other => {
            // Keycode has no numeric cast in rust-sdl2; its Display impl is
            // the SDL key name, which for a printable key is that character.
            let name = other.name();
            let mut chars = name.chars();
            match (chars.next(), chars.next()) {
                (Some(c), None) if c.is_ascii() => hud::action_for_char(c),
                _ if name == "Space" => hud::action_for_char(' '),
                _ => Action::None,
            }
        }
    }
}

fn main() {
    let o = cli::parse_args();
    let cfg = o.cfg.clone();
    let frames = if cfg.ticks == 0 { u32::MAX } else { cfg.ticks };

    let mut simulation = match Sim::new(cfg.clone()) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("error: {e}");
            std::process::exit(1);
        }
    };

    let sdl = sdl2::init().expect("SDL_Init");
    let video = sdl.video().expect("SDL video");
    let window = video
        .window("slimebench -- Rust / SDL2", cfg.width, cfg.height)
        .position_centered()
        .build()
        .expect("window");
    let mut canvas = window.into_canvas().build().expect("canvas");
    let creator = canvas.texture_creator();
    let mut tex = creator
        .create_texture_streaming(PixelFormatEnum::ARGB8888, cfg.width, cfg.height)
        .expect("texture");
    let mut events = sdl.event_pump().expect("event pump");

    let cells = (cfg.width * cfg.height) as usize;
    let mut gray = vec![0u8; cells];
    let mut stats = RenderStats::new(if frames == u32::MAX { 100_000 } else { frames as usize });
    let mut hud = Hud::new("rust / sdl2", o.want_hud);
    let mut freeze = o.freeze_sim;
    let mut bright = o.display_max;

    for _ in 0..frames {
        for ev in events.poll_iter() {
            match ev {
                Event::Quit { .. } => hud.want_quit = true,
                Event::KeyDown { keycode: Some(k), .. } => {
                    let a = sdl_action(k);
                    hud.apply(&mut simulation.cfg, &mut freeze, &mut bright, a);
                }
                _ => {}
            }
        }
        hud.service(&mut simulation);
        if hud.want_quit {
            break;
        }

        let s0 = now_ns();
        if !freeze && (!hud.paused || hud.step_once) {
            simulation.tick();
            hud.tick += 1;
            hud.step_once = false;
        }
        let sim_ms = (now_ns() - s0) as f64 / 1e6;

        let r0 = now_ns();
        simulation.render_gray(&mut gray, bright);

        // Timed separately and subtracted below: the overlay is not part of
        // the grid -> texture -> screen path the class R number reports.
        let h0 = now_ns();
        hud::draw(&hud, &simulation.cfg, &mut gray, bright);
        let hud_ns = now_ns() - h0;
        tex.with_lock(None, |buf: &mut [u8], pitch: usize| {
            for y in 0..cfg.height as usize {
                let row = &mut buf[y * pitch..y * pitch + cfg.width as usize * 4];
                let src = &gray[y * cfg.width as usize..(y + 1) * cfg.width as usize];
                for (px, &v) in row.chunks_exact_mut(4).zip(src) {
                    px[0] = v;
                    px[1] = v;
                    px[2] = v;
                    px[3] = 0xFF;
                }
            }
        })
        .expect("lock");
        canvas.clear();
        canvas.copy(&tex, None, None).expect("copy");
        canvas.present();
        let frame_ns = now_ns() - r0;
        stats.add(frame_ns - hud_ns);
        hud.observe(sim_ms, (frame_ns - hud_ns) as f64 / 1e6);

        if stats.since_title >= 60 {
            let ms = stats.recent_mean(60);
            let _ = canvas.window_mut().set_title(&format!(
                "slimebench -- Rust / SDL2 -- {:.2} ms/frame ({:.0} fps)",
                ms,
                if ms > 0.0 { 1000.0 / ms } else { 0.0 }
            ));
            stats.since_title = 0;
        }
    }

    if o.want_json {
        let backend = format!("sdl2{}", hud.json_suffix());
        if let Some(j) = stats.json(&simulation, &backend) {
            println!("{j}");
        }
    }
}
