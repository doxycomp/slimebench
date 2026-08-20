//! slimebench -- Rust + raylib frontend (benchmark class R).
//!
//! Same work as the SDL2 frontend on the identical byte buffer. raylib's
//! `UNCOMPRESSED_GRAYSCALE` takes the 8-bit buffer straight from
//! `Sim::render_gray`, where SDL2 needs ARGB8888 and therefore an expansion
//! loop over every pixel. The asymmetry is deliberate -- see the sibling file.

// Each frontend includes the whole simulation via #[path]; the parts this
// binary does not call are not dead code, they just belong to another one.
#![allow(dead_code)]

use raylib::ffi;
use std::ffi::CString;

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

    let cells = (cfg.width * cfg.height) as usize;
    let mut gray = vec![0u8; cells];
    let mut stats = RenderStats::new(if frames == u32::MAX { 100_000 } else { frames as usize });
    let mut hud = Hud::new("rust / raylib", o.want_hud);
    let mut freeze = o.freeze_sim;
    let mut bright = o.display_max;

    // The safe wrapper owns the window handle and will not hand out a raw
    // Texture2D to UpdateTexture, so the frontend goes through raylib::ffi
    // directly. That is the same call sequence the C frontend makes, which is
    // the point -- this measures raylib, not a wrapper's opinion of it.
    unsafe {
        ffi::SetTraceLogLevel(ffi::TraceLogLevel::LOG_WARNING as i32);
        let title = CString::new("slimebench -- Rust / raylib").unwrap();
        ffi::InitWindow(cfg.width as i32, cfg.height as i32, title.as_ptr());
        // raylib closes the window on Escape by default; the HUD wants to see
        // the key so quitting goes through the same path in both frontends.
        ffi::SetExitKey(0);

        let img = ffi::Image {
            data: gray.as_mut_ptr() as *mut std::ffi::c_void,
            width: cfg.width as i32,
            height: cfg.height as i32,
            mipmaps: 1,
            format: ffi::PixelFormat::PIXELFORMAT_UNCOMPRESSED_GRAYSCALE as i32,
        };
        let tex = ffi::LoadTextureFromImage(img);
        let black = ffi::Color { r: 0, g: 0, b: 0, a: 255 };
        let white = ffi::Color { r: 255, g: 255, b: 255, a: 255 };

        for _ in 0..frames {
            if ffi::WindowShouldClose() {
                break;
            }
            // GetCharPressed drains the character queue; the three
            // non-character keys are polled separately.
            loop {
                let ch = ffi::GetCharPressed();
                if ch == 0 {
                    break;
                }
                let a = if (0..128).contains(&ch) {
                    hud::action_for_char(ch as u8 as char)
                } else {
                    Action::None
                };
                hud.apply(&mut simulation.cfg, &mut freeze, &mut bright, a);
            }
            for (key, act) in [
                (ffi::KeyboardKey::KEY_ESCAPE, Action::Quit),
                (ffi::KeyboardKey::KEY_TAB, Action::Hud),
                (ffi::KeyboardKey::KEY_F1, Action::Help),
            ] {
                if ffi::IsKeyPressed(key as i32) {
                    hud.apply(&mut simulation.cfg, &mut freeze, &mut bright, act);
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

            let h0 = now_ns();
            hud::draw(&hud, &simulation.cfg, &mut gray, bright);
            let hud_ns = now_ns() - h0;

            ffi::UpdateTexture(tex, gray.as_ptr() as *const std::ffi::c_void);

            ffi::BeginDrawing();
            ffi::ClearBackground(black);
            ffi::DrawTexture(tex, 0, 0, white);
            ffi::EndDrawing();
            let frame_ns = now_ns() - r0;
            stats.add(frame_ns - hud_ns);
            hud.observe(sim_ms, (frame_ns - hud_ns) as f64 / 1e6);

            if stats.since_title >= 60 {
                let ms = stats.recent_mean(60);
                let t = CString::new(format!(
                    "slimebench -- Rust / raylib -- {:.2} ms/frame ({:.0} fps)",
                    ms,
                    if ms > 0.0 { 1000.0 / ms } else { 0.0 }
                ))
                .unwrap();
                ffi::SetWindowTitle(t.as_ptr());
                stats.since_title = 0;
            }
        }

        ffi::UnloadTexture(tex);
        ffi::CloseWindow();
    }

    if o.want_json {
        let backend = format!("raylib{}", hud.json_suffix());
        if let Some(j) = stats.json(&simulation, &backend) {
            println!("{j}");
        }
    }
}
