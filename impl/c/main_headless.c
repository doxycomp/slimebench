/* slimebench -- C headless benchmark frontend (class S). */

#include <stdio.h>
#include <stdlib.h>

#include <string.h>

#include "sb_cli.h"
#include "sb_verify.h"
#include "sb_parallel.h"

int main(int argc, char **argv) {
    sb_config cfg;
    sb_cli_opts opt;
    if (sb_parse_args(argc, argv, &cfg, &opt) != 0) return 2;

    sb_sim sim;
    if (sb_sim_init(&sim, &cfg) != 0) {
        fprintf(stderr, "error: init failed (width/height must be powers of two)\n");
        return 1;
    }

    sb_pool *pool = NULL;
    if (cfg.threads > 1) {
        pool = sb_pool_create(&sim);
        if (!pool) {          /* message already on stderr */
            sb_sim_free(&sim);
            return 3;
        }
    }
#define SB_TICK() (pool ? sb_tick_parallel(&sim, pool) : sb_tick(&sim))

    for (uint32_t t = 0; t < cfg.warmup; t++) SB_TICK();
    sim.ns_agents = 0;
    sim.ns_diffuse = 0;

    /* Verification, if either flag is present. Opened after the warm-up so a
     * chain starts at tick 1 of the measured run in both modes. */
    FILE *chain_out = NULL, *chain_in = NULL;
    int verify_bad = 0;
    if (opt.emit_chain) {
        chain_out = fopen(opt.emit_chain, "w");
        if (!chain_out) {
            fprintf(stderr, "error: cannot write %s\n", opt.emit_chain);
            sb_sim_free(&sim);
            return 3;
        }
        char hdr[256];
        sb_chain_header(&cfg, hdr, sizeof hdr);
        fprintf(chain_out, "# slimebench verify chain v1\n"
                           "# config %s\n"
                           "# blocks %d  every %u\n",
                hdr, SB_VERIFY_BLOCKS, cfg.hash_every ? cfg.hash_every : 1u);
    }
    if (opt.verify_chain) {
        chain_in = fopen(opt.verify_chain, "r");
        if (!chain_in) {
            fprintf(stderr, "error: cannot read %s\n", opt.verify_chain);
            if (chain_out) fclose(chain_out);
            sb_sim_free(&sim);
            return 3;
        }
        /* The header names the configuration the chain was recorded from.
         * Verifying against a different one produces a mismatch that says
         * nothing about the machine, so it is refused rather than reported. */
        char want[256], have[256], line[512];
        sb_chain_header(&cfg, have, sizeof have);
        want[0] = '\0';
        const char *tag = "# config ";
        const size_t taglen = strlen(tag);
        while (fgets(line, sizeof line, chain_in)) {
            if (line[0] != '#') { fseek(chain_in, -(long)strlen(line), SEEK_CUR); break; }
            if (strncmp(line, tag, taglen) == 0) {
                size_t n = strlen(line + taglen);
                while (n && (line[taglen + n - 1] == '\n' ||
                             line[taglen + n - 1] == '\r')) n--;
                if (n < sizeof want) { memcpy(want, line + taglen, n); want[n] = '\0'; }
            }
        }
        if (want[0] && strcmp(want, have) != 0) {
            fprintf(stderr, "error: this chain was recorded from a different "
                            "configuration\n  chain: %s\n  here : %s\n",
                    want, have);
            fclose(chain_in);
            if (chain_out) fclose(chain_out);
            sb_sim_free(&sim);
            return 3;
        }
    }

    double *tick_ms = (double *)malloc((size_t)(cfg.ticks ? cfg.ticks : 1) * sizeof(double));
    if (!tick_ms) { sb_sim_free(&sim); return 1; }

    const uint64_t t_start = sb_now_ns();
    for (uint32_t t = 0; t < cfg.ticks; t++) {
        const uint64_t a = sb_now_ns();
        SB_TICK();
        const uint64_t b = sb_now_ns();
        tick_ms[t] = (double)(b - a) / 1e6;

        if (cfg.hash_every && ((t + 1) % cfg.hash_every == 0)) {
            fprintf(stderr, "tick %u grid=0x%08X agents=0x%08X\n",
                    t + 1, sb_hash_grid(&sim), sb_hash_agents(&sim));
        }

        /* Verification runs on its own schedule, every tick unless told
         * otherwise: a fault that lasts one tick is exactly the kind worth
         * catching, and checking every hundredth tick would miss it. */
        if (chain_out || chain_in) {
            const uint32_t every = cfg.hash_every ? cfg.hash_every : 1u;
            if ((t + 1) % every == 0) {
                sb_checkpoint got;
                sb_checkpoint_take(&sim, t + 1, &got);
                if (chain_out) sb_checkpoint_write(chain_out, &got);
                if (chain_in) {
                    sb_checkpoint want;
                    const int r = sb_checkpoint_read(chain_in, &want);
                    if (r == 0) {
                        fprintf(stderr, "verify: chain ended at tick %u; "
                                        "run fewer ticks or record a longer "
                                        "one\n", t + 1);
                        verify_bad++;
                        break;
                    }
                    if (r < 0) {
                        fprintf(stderr, "verify: malformed chain file\n");
                        verify_bad++;
                        break;
                    }
                    if (want.tick != got.tick) {
                        fprintf(stderr, "verify: chain is at tick %u, we are "
                                        "at %u -- --hash-every must match the "
                                        "recording\n", want.tick, got.tick);
                        verify_bad++;
                        break;
                    }
                    if (sb_checkpoint_diff(&sim, &want, &got, stderr) >= 0) {
                        verify_bad++;
                        /* One report, not one per tick: after the first
                         * divergence every later tick is wrong too, and
                         * printing all of them buries the one that matters. */
                        break;
                    }
                }
            }
        }
    }
    const double ms_total = (double)(sb_now_ns() - t_start) / 1e6;

    if (opt.dump_grid && sb_dump_grid(&sim, opt.dump_grid) != 0) {
        fprintf(stderr, "error: could not write %s\n", opt.dump_grid);
    }

    if (opt.want_json) {
        sb_emit_json(&sim, "c", pool ? "pthreads" : "headless",
                     pool ? "P" : "S", ms_total, tick_ms, cfg.ticks);
    } else {
        printf("%s %ux%u agents=%u ticks=%u update=%s threads=%u%s\n",
               cfg.preset, cfg.width, cfg.height, cfg.agents, cfg.ticks,
               cfg.update == SB_UPDATE_DEFERRED ? "deferred" : "serial",
               cfg.threads,
               pool ? (cfg.reduce == SB_REDUCE_BINNED ? " reduce=binned"
                                                      : " reduce=private")
                    : "");
        printf("  grid_hash  0x%08X\n", sb_hash_grid(&sim));
        printf("  agent_hash 0x%08X\n", sb_hash_agents(&sim));
        printf("  total      %.2f ms  (%.4f ms/tick)\n",
               ms_total, cfg.ticks ? ms_total / cfg.ticks : 0.0);
        if (pool) {
            printf("  scratch    %.1f MiB\n",
                   (double)sb_pool_scratch_bytes(pool) / (1024.0 * 1024.0));
        } else {
            printf("  agents     %.2f ms\n", (double)sim.ns_agents / 1e6);
            printf("  diffuse    %.2f ms\n", (double)sim.ns_diffuse / 1e6);
        }
    }

    sb_pool_report_phases(pool, cfg.ticks);

#undef SB_TICK
    free(tick_ms);
    sb_pool_destroy(pool);
    if (chain_out) {
        fclose(chain_out);
        fprintf(stderr, "recorded %u checkpoints to %s\n",
                cfg.ticks / (cfg.hash_every ? cfg.hash_every : 1u),
                opt.emit_chain);
    }
    if (chain_in) {
        fclose(chain_in);
        if (verify_bad == 0)
            fprintf(stderr, "verify: OK -- every checkpoint matched\n");
    }

    sb_sim_free(&sim);
#if defined(SB_BRANCH_STATS) && SB_BRANCH_STATS
    sb_branch_report();
#endif
    /* A machine that computed the wrong thing must not exit 0, whatever the
     * timings say. */
    return verify_bad ? 4 : 0;
}
