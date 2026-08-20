// sb::Sim <-> sb_hud_view, the glue the C++ port needs.
//
// The overlay itself, and the bitmap font it draws with, are ../c/sb_hud.h
// and ../c/sb_font.h -- included here rather than reimplemented. Every other
// file in this directory is a genuine C++ port of its C counterpart, because
// comparing the two languages is the point; a second copy of a bitmap font
// would compare nothing and drift.
#pragma once

#include <cstdio>

#include "../c/sb_hud.h"
#include "sim.hpp"

namespace sb {

inline sb_hud_view hudViewOf(const Sim& sim) {
    const Config& c = sim.cfg();
    sb_hud_view v{};
    v.width = c.width;
    v.height = c.height;
    v.agents = c.agents;
    v.threads = c.threads;
    v.rot_steps = c.rot_steps;
    v.ndir = kNdir;
    v.deposit = c.deposit;
    v.decay = c.decay;
    v.sensor_dist = c.sensor_dist;
    v.step = c.step;
    v.deferred = c.update == Update::Deferred;
    return v;
}

inline void hudViewInto(const sb_hud_view& v, Sim& sim) {
    sim.setTunables(v.deposit, v.decay, v.sensor_dist, v.step, v.rot_steps);
}

// The two deferred requests both frontends handle identically.
inline void hudService(sb_hud& h, Sim& sim, sb_hud_view& v) {
    if (h.want_hash) {
        std::fprintf(stderr, "tick %u grid=0x%08X agents=0x%08X%s\n",
                     h.tick, sim.hashGrid(), sim.hashAgents(),
                     h.edited ? "  (edited -- not reproducible)" : "");
        h.want_hash = 0;
    }
    if (h.want_reset) {
        // Reset means "start over with what I have now", not "undo my
        // keypresses", so the edited config is what gets reinstated.
        const Config now = sim.cfg();   // copy: sim is about to be replaced
        sim = Sim(now);
        h.want_reset = 0;
        h.tick = 0;
        v = hudViewOf(sim);
    }
}

}  // namespace sb
