/* sb_sim <-> sb_hud_view, the two lines of glue the C port needs.
 *
 * Separate from sb_hud.h because that header is shared with the C++ port,
 * which has its own sb::Sim and its own copy of these two functions.
 */
#ifndef SB_HUD_C_H
#define SB_HUD_C_H

#include "sb_core.h"
#include "sb_hud.h"

static inline sb_hud_view sb_hud_view_of(const sb_sim *s) {
    sb_hud_view v;
    v.width = s->cfg.width;
    v.height = s->cfg.height;
    v.agents = s->cfg.agents;
    v.threads = s->cfg.threads;
    v.rot_steps = s->cfg.rot_steps;
    v.ndir = SB_NDIR;
    v.deposit = s->cfg.deposit;
    v.decay = s->cfg.decay;
    v.sensor_dist = s->cfg.sensor_dist;
    v.step = s->cfg.step;
    v.deferred = s->cfg.update == SB_UPDATE_DEFERRED;
    return v;
}

static inline void sb_hud_view_into(const sb_hud_view *v, sb_sim *s) {
    s->cfg.rot_steps = v->rot_steps;
    s->cfg.deposit = v->deposit;
    s->cfg.decay = v->decay;
    s->cfg.sensor_dist = v->sensor_dist;
    s->cfg.step = v->step;
}

/* Both frontends do the same thing with the three deferred requests, so it
 * lives here rather than twice in the event loops. */
static inline int sb_hud_service(sb_hud *h, sb_sim *s, sb_hud_view *v) {
    if (h->want_hash) {
        fprintf(stderr, "tick %u grid=0x%08X agents=0x%08X%s\n",
                h->tick, sb_hash_grid(s), sb_hash_agents(s),
                h->edited ? "  (edited -- not reproducible)" : "");
        h->want_hash = 0;
    }
    if (h->want_reset) {
        /* Reinit with the current config, edits included: reset means "start
         * over with what I have now", not "undo my keypresses". */
        const sb_config now = s->cfg;
        sb_sim_free(s);
        if (sb_sim_init(s, &now) != 0) return 0;
        h->want_reset = 0;
        h->tick = 0;
        *v = sb_hud_view_of(s);
    }
    return 1;
}

#endif /* SB_HUD_C_H */
