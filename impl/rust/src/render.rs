//! Shared render-timing helper for the windowed Rust frontends (SPEC-1 11.1).
//!
//! A rendering backend benchmark measures the upload path
//! grid -> texture -> screen. If the simulation keeps running during the
//! measurement it dominates the frame and the backends come out
//! indistinguishable, so `--freeze-sim` stops it and every frame re-uploads
//! the same grid. Same contract as `impl/c/sb_render.h`, same JSON.

use crate::sim::Sim;

pub struct RenderStats {
    pub ms: Vec<f64>,
    pub since_title: usize,
}

impl RenderStats {
    pub fn new(cap: usize) -> Self {
        Self { ms: Vec::with_capacity(cap), since_title: 0 }
    }

    pub fn add(&mut self, ns: u64) {
        self.ms.push(ns as f64 / 1e6);
        self.since_title += 1;
    }

    /// Mean of the last `k` frames, for the window title.
    pub fn recent_mean(&self, k: usize) -> f64 {
        if self.ms.is_empty() {
            return 0.0;
        }
        let take = k.min(self.ms.len());
        self.ms[self.ms.len() - take..].iter().sum::<f64>() / take as f64
    }

    pub fn json(&self, sim: &Sim, backend: &str) -> Option<String> {
        if self.ms.is_empty() {
            return None;
        }
        let mut sorted = self.ms.clone();
        sorted.sort_by(|a, b| a.partial_cmp(b).unwrap());
        let n = sorted.len();
        let mean = self.ms.iter().sum::<f64>() / n as f64;
        let median = sorted[n / 2];
        let p99 = sorted[usize::min(n - 1, (n as f64 * 0.99) as usize)];
        let mpix = sim.cfg.width as f64 * sim.cfg.height as f64 / 1e6;

        Some(format!(
            concat!(
                r#"{{"schema":1,"impl":"rust","backend":"{}","class":"R","#,
                r#""preset":"{}","width":{},"height":{},"frames":{},"#,
                r#""ms_render_mean":{:.6},"ms_render_median":{:.6},"#,
                r#""ms_render_p99":{:.6},"fps_equiv":{:.2},"mpixels_per_s":{:.1}}}"#
            ),
            backend,
            sim.cfg.preset,
            sim.cfg.width,
            sim.cfg.height,
            n,
            mean,
            median,
            p99,
            if median > 0.0 { 1000.0 / median } else { 0.0 },
            if median > 0.0 { mpix * 1000.0 / median } else { 0.0 },
        ))
    }
}
