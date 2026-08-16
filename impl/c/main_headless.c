/* slimebench -- C headless benchmark frontend (class S). */

#include <stdio.h>
#include <stdlib.h>

#include "sb_cli.h"

int main(int argc, char **argv) {
    sb_config cfg;
    sb_cli_opts opt;
    if (sb_parse_args(argc, argv, &cfg, &opt) != 0) return 2;

    sb_sim sim;
    if (sb_sim_init(&sim, &cfg) != 0) {
        fprintf(stderr, "error: init failed (width/height must be powers of two)\n");
        return 1;
    }

    for (uint32_t t = 0; t < cfg.warmup; t++) sb_tick(&sim);
    sim.ns_agents = 0;
    sim.ns_diffuse = 0;

    double *tick_ms = (double *)malloc((size_t)(cfg.ticks ? cfg.ticks : 1) * sizeof(double));
    if (!tick_ms) { sb_sim_free(&sim); return 1; }

    const uint64_t t_start = sb_now_ns();
    for (uint32_t t = 0; t < cfg.ticks; t++) {
        const uint64_t a = sb_now_ns();
        sb_tick(&sim);
        const uint64_t b = sb_now_ns();
        tick_ms[t] = (double)(b - a) / 1e6;

        if (cfg.hash_every && ((t + 1) % cfg.hash_every == 0)) {
            fprintf(stderr, "tick %u grid=0x%08X agents=0x%08X\n",
                    t + 1, sb_hash_grid(&sim), sb_hash_agents(&sim));
        }
    }
    const double ms_total = (double)(sb_now_ns() - t_start) / 1e6;

    if (opt.dump_grid && sb_dump_grid(&sim, opt.dump_grid) != 0) {
        fprintf(stderr, "error: could not write %s\n", opt.dump_grid);
    }

    if (opt.want_json) {
        sb_emit_json(&sim, "c", "headless", "S", ms_total, tick_ms, cfg.ticks);
    } else {
        printf("%s %ux%u agents=%u ticks=%u update=%s\n",
               cfg.preset, cfg.width, cfg.height, cfg.agents, cfg.ticks,
               cfg.update == SB_UPDATE_DEFERRED ? "deferred" : "serial");
        printf("  grid_hash  0x%08X\n", sb_hash_grid(&sim));
        printf("  agent_hash 0x%08X\n", sb_hash_agents(&sim));
        printf("  total      %.2f ms  (%.4f ms/tick)\n",
               ms_total, cfg.ticks ? ms_total / cfg.ticks : 0.0);
        printf("  agents     %.2f ms\n", (double)sim.ns_agents / 1e6);
        printf("  diffuse    %.2f ms\n", (double)sim.ns_diffuse / 1e6);
    }

    free(tick_ms);
    sb_sim_free(&sim);
    return 0;
}
