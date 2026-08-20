//! slimebench -- on-screen HUD and keyboard control (Rust frontends).
//!
//! A port of impl/c/sb_hud.h and impl/c/sb_font.h, not a binding to them.
//! Every other file in this crate is a real Rust port of its C counterpart
//! because comparing the two is the point, and a frontend that reached into
//! the C tree for its font would be the one place where that stopped being
//! true. The glyphs and the key map are therefore duplicated, and one FNV-1a
//! constant keeps them from drifting: FONT_HASH here and SB_FONT_HASH in
//! sb_font.h are the same number over the same bytes. The test below catches
//! an edit to this table; sb_hud_init() catches an edit to the C one and says
//! which file to regenerate.
//!
//! The overlay is drawn into the 8-bit greyscale buffer both frontends already
//! produce, before upload, so SDL2 and raylib get identical pixels.

#![allow(dead_code)]

use crate::sim::{Config, Sim, Update};

pub const GLYPH_W: usize = 5;
pub const GLYPH_H: usize = 7;

/// The glyph table, generated from impl/c/sb_font.h by
/// scratchpad/gen_rust_font.py -- see the test at the bottom of this file.
/// Seven rows of five characters per glyph, '#' set and '.' clear.
#[rustfmt::skip]
static FONT: [&[u8; 35]; 57] = [
    b".###.#...##...#######...##...##...#",  // A
    b"####.#...##...#####.#...##...#####.",  // B
    b".###.#...##....#....#....#...#.###.",  // C
    b"####.#...##...##...##...##...#####.",  // D
    b"######....#....####.#....#....#####",  // E
    b"######....#....####.#....#....#....",  // F
    b".###.#...##....#.####...##...#.###.",  // G
    b"#...##...##...#######...##...##...#",  // H
    b".###...#....#....#....#....#...###.",  // I
    b"..###...#....#....#....#.#..#..##..",  // J
    b"#...##..#.#.#..##...#.#..#..#.#...#",  // K
    b"#....#....#....#....#....#....#####",  // L
    b"#...###.###.#.##...##...##...##...#",  // M
    b"#...###..##.#.##..###...##...##...#",  // N
    b".###.#...##...##...##...##...#.###.",  // O
    b"####.#...##...#####.#....#....#....",  // P
    b".###.#...##...##...##.#.##..#..##.#",  // Q
    b"####.#...##...#####.#.#..#..#.#...#",  // R
    b".#####....#.....###.....#....#####.",  // S
    b"#####..#....#....#....#....#....#..",  // T
    b"#...##...##...##...##...##...#.###.",  // U
    b"#...##...##...##...##...#.#.#...#..",  // V
    b"#...##...##...##...##.#.###.###...#",  // W
    b"#...##...#.#.#...#...#.#.#...##...#",  // X
    b"#...##...#.#.#...#....#....#....#..",  // Y
    b"#####....#...#...#...#...#....#####",  // Z
    b".###.#...##..###.#.###..##...#.###.",  // 0
    b"..#...##....#....#....#....#...###.",  // 1
    b".###.#...#....#...#...#...#...#####",  // 2
    b"#####...#...#.....#.....##...#.###.",  // 3
    b"...#...##..#.#.#..#.#####...#....#.",  // 4
    b"######....####.....#....##...#.###.",  // 5
    b"..##..#...#....####.#...##...#.###.",  // 6
    b"#####....#...#...#...#....#....#...",  // 7
    b".###.#...##...#.###.#...##...#.###.",  // 8
    b".###.#...##...#.####....#...#..##..",  // 9
    b"...................................",  // space
    b"..........................##...##..",  // .
    b".....................##...##...#...",  // ,
    b"......##...##........##...##.......",  // :
    b"...............#####...............",  // -
    b".......#....#..#####..#....#.......",  // +
    b"....#....#...#...#...#...#....#....",  // /
    b"##..###..#...#...#...#...#..###..##",  // %
    b"..........#####.....#####..........",  // =
    b"..##..#...#....#....#.....#.....##.",  // (
    b".##.....#.....#....#....#...#..##..",  // )
    b".###..#....#....#....#....#....###.",  // [
    b".###....#....#....#....#....#..###.",  // ]
    b"...#...#...#...#.....#.....#.....#.",  // <
    b".#.....#.....#.....#...#...#...#...",  // >
    b".###.#...#....#...#...#.........#..",  // ?
    b"..#....#....#....#....#.........#..",  // !
    b".....#.#.#.###.#####.###.#.#.#.....",  // *
    b".#.#..#.#.#####.#.#.#####.#.#......",  // #
    b"..............................#####",  // _
    b"..#....#....#....#....#....#....#..",  // |
];

const FONT_CHARS: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 .,:-+/%=()[]<>?!*#_|";

/// Drawn for anything not in the table, so a missing glyph is visible.
static MISSING: [u8; 35] = *b"######...##...##...##...##...######";

/// FNV-1a over the glyph bytes. impl/c/sb_font.h holds the same table; if the
/// two ever drift, this is where it shows.
pub const FONT_HASH: u32 = 0x6856D243;

pub fn glyph(c: u8) -> &'static [u8; 35] {
    let c = c.to_ascii_uppercase();
    match FONT_CHARS.iter().position(|&k| k == c) {
        Some(i) => FONT[i],
        None => &MISSING,
    }
}

// ---- actions --------------------------------------------------------------

/// Frontends translate their own keycodes into these; nothing below this line
/// knows what SDL2 or raylib call a key.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Action {
    None,
    Quit,
    Pause,
    Step,
    Reset,
    Hud,
    Help,
    Hash,
    Freeze,
    DepositDn,
    DepositUp,
    DecayDn,
    DecayUp,
    SensorDn,
    SensorUp,
    StepLenDn,
    StepLenUp,
    RotDn,
    RotUp,
    BrightDn,
    BrightUp,
}

/// ASCII -> action, the same table the C frontends use. Keys without a
/// character (Escape, Tab, F1) are mapped by the frontend directly.
pub fn action_for_char(c: char) -> Action {
    match c.to_ascii_lowercase() {
        'q' => Action::Quit,
        ' ' => Action::Pause,
        'n' => Action::Step,
        'r' => Action::Reset,
        'h' => Action::Help,
        'c' => Action::Hash,
        'f' => Action::Freeze,
        '1' => Action::DepositDn,
        '2' => Action::DepositUp,
        '3' => Action::DecayDn,
        '4' => Action::DecayUp,
        '5' => Action::SensorDn,
        '6' => Action::SensorUp,
        '7' => Action::StepLenDn,
        '8' => Action::StepLenUp,
        '9' => Action::RotDn,
        '0' => Action::RotUp,
        '-' | '_' => Action::BrightDn,
        '=' | '+' => Action::BrightUp,
        _ => Action::None,
    }
}

// ---- state ----------------------------------------------------------------

pub struct Hud {
    pub show_hud: bool,
    pub show_help: bool,
    pub paused: bool,
    pub step_once: bool,
    pub want_quit: bool,
    pub want_reset: bool,
    pub want_hash: bool,
    /// A parameter was changed at runtime, so the hashes reproduce nothing.
    pub edited: bool,
    pub tick: u32,
    pub sim_ms: f64,
    pub render_ms: f64,
    pub label: &'static str,
}

impl Hud {
    pub fn new(label: &'static str, show: bool) -> Self {
        Hud {
            show_hud: show,
            show_help: false,
            paused: false,
            step_once: false,
            want_quit: false,
            want_reset: false,
            want_hash: false,
            edited: false,
            tick: 0,
            sim_ms: 0.0,
            render_ms: 0.0,
            label,
        }
    }

    /// Slow enough to read, fast enough to react.
    pub fn observe(&mut self, sim_ms: f64, render_ms: f64) {
        const A: f64 = 0.1;
        self.sim_ms = if self.sim_ms == 0.0 { sim_ms } else { self.sim_ms + A * (sim_ms - self.sim_ms) };
        self.render_ms =
            if self.render_ms == 0.0 { render_ms } else { self.render_ms + A * (render_ms - self.render_ms) };
    }

    /// Appended to the backend name in any JSON emitted after an edit, so an
    /// interactively fiddled run cannot be mistaken for a benchmark.
    pub fn json_suffix(&self) -> &'static str {
        if self.edited { "+edited" } else { "" }
    }

    /// Applies one action. Steps are multiplicative where the parameter spans
    /// orders of magnitude and additive where it does not.
    pub fn apply(&mut self, cfg: &mut Config, freeze: &mut bool, bright: &mut f32, a: Action) {
        let mut edit = true;
        match a {
            Action::None => return,
            Action::Quit => { self.want_quit = true; edit = false; }
            Action::Pause => { self.paused = !self.paused; edit = false; }
            Action::Step => { self.step_once = true; self.paused = true; edit = false; }
            Action::Reset => { self.want_reset = true; edit = false; }
            Action::Hash => { self.want_hash = true; edit = false; }
            Action::Hud => { self.show_hud = !self.show_hud; edit = false; }
            Action::Help => {
                self.show_help = !self.show_help;
                if self.show_help { self.show_hud = true; }
                edit = false;
            }
            Action::Freeze => { *freeze = !*freeze; edit = false; }
            Action::DepositDn => cfg.deposit = (cfg.deposit / 1.25).clamp(0.001, 1000.0),
            Action::DepositUp => cfg.deposit = (cfg.deposit * 1.25).clamp(0.001, 1000.0),
            Action::DecayDn => cfg.decay = (cfg.decay - 0.005).clamp(0.50, 1.0),
            Action::DecayUp => cfg.decay = (cfg.decay + 0.005).clamp(0.50, 1.0),
            Action::SensorDn => cfg.sensor_dist = (cfg.sensor_dist - 1.0).clamp(1.0, 128.0),
            Action::SensorUp => cfg.sensor_dist = (cfg.sensor_dist + 1.0).clamp(1.0, 128.0),
            Action::StepLenDn => cfg.step = (cfg.step - 0.1).clamp(0.1, 16.0),
            Action::StepLenUp => cfg.step = (cfg.step + 0.1).clamp(0.1, 16.0),
            // Direction indices are integers in [1, NDIR/4]; wrapping them
            // would make a fat-fingered keypress silently reverse the turn.
            Action::RotDn => { if cfg.rot_steps > 1 { cfg.rot_steps -= 1; } }
            Action::RotUp => { if cfg.rot_steps < crate::dirtable::NDIR / 4 { cfg.rot_steps += 1; } }
            Action::BrightDn => { *bright *= 1.25; edit = false; }
            Action::BrightUp => { *bright /= 1.25; edit = false; }
        }
        if edit {
            self.edited = true;
        }
    }

    /// The two deferred requests both frontends handle identically.
    pub fn service(&mut self, sim: &mut Sim) {
        if self.want_hash {
            eprintln!(
                "tick {} grid=0x{:08X} agents=0x{:08X}{}",
                self.tick,
                sim.hash_grid(),
                sim.hash_agents(),
                if self.edited { "  (edited -- not reproducible)" } else { "" }
            );
            self.want_hash = false;
        }
        if self.want_reset {
            // Reset means "start over with what I have now", not "undo my
            // keypresses", so the edited config is what gets reinstated.
            if let Ok(fresh) = Sim::new(sim.cfg.clone()) {
                *sim = fresh;
            }
            self.want_reset = false;
            self.tick = 0;
        }
    }
}

// ---- drawing --------------------------------------------------------------

const FG: u8 = 255;

fn dim(g: &mut [u8], w: u32, h: u32, x1: i32, y0: i32, y1: i32) {
    let (w, h) = (w as i32, h as i32);
    for y in y0.max(0)..y1.min(h) {
        for x in 0..x1.min(w) {
            let p = &mut g[(y as usize) * (w as usize) + x as usize];
            *p /= 4;
        }
    }
}

fn text(g: &mut [u8], w: u32, h: u32, px0: i32, py: i32, scale: i32, s: &str) {
    let (wi, hi) = (w as i32, h as i32);
    let mut px = px0;
    for c in s.bytes() {
        if c != b' ' {
            let rows = glyph(c);
            for gy in 0..GLYPH_H as i32 {
                for gx in 0..GLYPH_W as i32 {
                    if rows[(gy as usize) * GLYPH_W + gx as usize] != b'#' {
                        continue;
                    }
                    for sy in 0..scale {
                        for sx in 0..scale {
                            let x = px + gx * scale + sx;
                            let y = py + gy * scale + sy;
                            if x < 0 || y < 0 || x >= wi || y >= hi {
                                continue;
                            }
                            g[(y as usize) * (w as usize) + x as usize] = FG;
                        }
                    }
                }
            }
        }
        px += (GLYPH_W as i32 + 1) * scale;
    }
}

/// Roughly ninety characters across the window, clamped to something readable.
fn scale_for(w: u32) -> i32 {
    ((w / 560) as i32).clamp(1, 4)
}

const HELP: &[&str] = &[
    "KEYS",
    "  SPACE    PAUSE / RESUME",
    "  N        SINGLE STEP",
    "  R        RESET SIMULATION",
    "  TAB      HUD ON / OFF",
    "  H  F1    THIS HELP",
    "  C        PRINT HASHES TO STDERR",
    "  F        FREEZE SIM (RENDER ONLY)",
    "  1 / 2    DEPOSIT    DOWN / UP",
    "  3 / 4    DECAY      DOWN / UP",
    "  5 / 6    SENSOR     DOWN / UP",
    "  7 / 8    STEP       DOWN / UP",
    "  9 / 0    ROT STEPS  DOWN / UP",
    "  - / =    BRIGHTNESS DOWN / UP",
    "  Q  ESC   QUIT",
    "",
    "CHANGING A PARAMETER LEAVES THE SPEC-1",
    "CONFIGURATION. THE RUN IS THEN MARKED",
    "EDITED AND ITS HASHES REPRODUCE NOTHING.",
];

/// Draws the overlay into the greyscale buffer. Call after `render_gray` and
/// before the upload.
pub fn draw(hud: &Hud, cfg: &Config, g: &mut [u8], display_max: f32) {
    if !hud.show_hud {
        return;
    }
    let (w, h) = (cfg.width, cfg.height);
    let sc = scale_for(w);
    let lh = (GLYPH_H as i32 + 3) * sc;
    let pad = 4 * sc;

    // Lowercase text: `glyph` folds to uppercase, so the HUD reads as caps
    // without a second pass.
    let fps = if hud.sim_ms + hud.render_ms > 0.0 { 1000.0 / (hud.sim_ms + hud.render_ms) } else { 0.0 };
    let lines = [
        format!("slimebench  {}  {}x{}  {} agents", hud.label, w, h, cfg.agents),
        format!(
            "tick {}   sim {:.2} ms   draw {:.2} ms   {:.0} fps",
            hud.tick, hud.sim_ms, hud.render_ms, fps
        ),
        format!(
            "deposit {:.3}  decay {:.3}  sensor {:.1}  step {:.2}  rot {}",
            cfg.deposit, cfg.decay, cfg.sensor_dist, cfg.step, cfg.rot_steps
        ),
        format!(
            "update {}  threads {}  bright {:.0}",
            if cfg.update == Update::Deferred { "deferred" } else { "serial" },
            cfg.threads,
            display_max
        ),
        format!(
            "{}{}   h for help",
            if hud.paused { "paused" } else { "running" },
            if hud.edited { "   edited -- not reproducible" } else { "" }
        ),
    ];

    let maxlen = lines.iter().map(|l| l.len()).max().unwrap_or(0) as i32;
    let bw = maxlen * (GLYPH_W as i32 + 1) * sc + 2 * pad;
    let bh = lines.len() as i32 * lh + 2 * pad;
    dim(g, w, h, bw, 0, bh);
    for (i, l) in lines.iter().enumerate() {
        text(g, w, h, pad, pad + i as i32 * lh, sc, l);
    }

    if !hud.show_help {
        return;
    }
    let hmax = HELP.iter().map(|l| l.len()).max().unwrap_or(0) as i32;
    let hy = bh + pad;
    // Same width as the status panel, so the two read as one block.
    let hw = (hmax * (GLYPH_W as i32 + 1) * sc + 2 * pad).max(bw);
    dim(g, w, h, hw, hy - pad, hy + HELP.len() as i32 * lh + pad);
    for (i, l) in HELP.iter().enumerate() {
        text(g, w, h, pad, hy + i as i32 * lh, sc, l);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The C font in impl/c/sb_font.h is the original; this table is generated
    /// from it and FONT_HASH was computed from the C bytes at generation time.
    /// This test therefore catches an edit made here; the matching check in
    /// sb_hud_init() catches one made there.
    #[test]
    fn font_matches_the_c_table() {
        let mut h: u32 = 0x811C_9DC5;
        for g in FONT.iter() {
            for &b in g.iter() {
                h = (h ^ b as u32).wrapping_mul(0x0100_0193);
            }
        }
        assert_eq!(h, FONT_HASH, "glyph table changed; regenerate from sb_font.h");
        assert_eq!(FONT.len(), FONT_CHARS.len());
    }

    #[test]
    fn every_glyph_is_five_by_seven() {
        for (i, g) in FONT.iter().enumerate() {
            assert_eq!(g.len(), GLYPH_W * GLYPH_H, "glyph {i}");
            assert!(g.iter().all(|&b| b == b'#' || b == b'.'), "glyph {i}");
        }
    }
}
