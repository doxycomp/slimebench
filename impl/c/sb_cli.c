/* The CLI parser and the result printer declared in sb_cli.h.
 *
 * Nothing here decides anything: the flag set, the presets and the JSON
 * field names are SPEC-1 section 10, and the header carries the argument
 * for why they are shared across every C frontend rather than repeated.
 * This file is the parsing itself, which is dull on purpose -- a CLI that
 * accepted a slightly different spelling per frontend would produce two
 * measurements that look comparable and are not. */
#include "sb_cli.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "sb_simd.h"
#include "sb_asm.h"

void sb_print_usage(FILE *f, const char *argv0) {
    fprintf(f,
        "usage: %s [options]   (slimebench " SB_SPEC_VERSION ")\n"
        "  --preset NAME        tiny|small|medium|large|huge|browser\n"
        "  --width N --height N powers of two\n"
        "  --agents N  --ticks N  --warmup N  --seed N\n"
        "  --update MODE        serial|deferred\n"
        "  --threads N          class P, requires --update deferred\n"
        "  --simd-agents        vectorised agent pass, deferred only\n"
        "  --agent-tile N       re-sort agents into 8x8 tiles every N ticks\n"
        "  --deposit-reduce M   private|binned  (SPEC-1 5.6)\n"
        "  --sensor-dist F  --sensor-steps N  --rot-steps N\n"
        "  --step F  --deposit F  --decay F\n"
        "  --hud  | --no-hud    on-screen overlay (default on, off with --json)\n"
        "  --fullscreen         windowed frontends: desktop fullscreen\n"
        "  --headless  --render  --freeze-sim\n"
        "  --json  --hash-every N  --dump-grid PATH  --display-max F\n"
        "  --emit-chain PATH    record a verification chain (see sb_verify.h)\n"
        "  --verify PATH        check this machine against one\n"
        "  -h, --help\n",
        argv0);
}

static int apply_preset(sb_config *c, const char *name) {
    if (!strcmp(name, "tiny")) {
        c->width = 512;  c->height = 512;  c->agents = 65536;    c->ticks = 1000;
    } else if (!strcmp(name, "small")) {
        c->width = 1024; c->height = 1024; c->agents = 262144;   c->ticks = 1000;
    } else if (!strcmp(name, "medium")) {
        c->width = 2048; c->height = 2048; c->agents = 1048576;  c->ticks = 1000;
    } else if (!strcmp(name, "large")) {
        c->width = 4096; c->height = 4096; c->agents = 4194304;  c->ticks = 500;
    } else if (!strcmp(name, "huge")) {
        c->width = 8192; c->height = 8192; c->agents = 16777216; c->ticks = 100;
    } else if (!strcmp(name, "browser")) {
        c->width = 1024; c->height = 1024; c->agents = 262144;   c->ticks = 0;
    } else {
        return 1;
    }
    c->preset = name;
    return 0;
}

#define NEED_VALUE(flag)                                                    \
    do {                                                                    \
        if (i + 1 >= argc) {                                                \
            fprintf(stderr, "error: %s requires a value\n", (flag));        \
            return 2;                                                       \
        }                                                                   \
    } while (0)

int sb_parse_args(int argc, char **argv, sb_config *cfg, sb_cli_opts *opt) {
    sb_config_defaults(cfg);
    memset(opt, 0, sizeof *opt);
    opt->display_max = 100.0f;
    opt->want_hud = -1;   /* resolved after parsing, once --json is known */

    for (int i = 1; i < argc; i++) {
        const char *a = argv[i];

        if (!strcmp(a, "-h") || !strcmp(a, "--help")) {
            sb_print_usage(stdout, argv[0]);
            exit(0);
        } else if (!strcmp(a, "--preset")) {
            NEED_VALUE(a);
            if (apply_preset(cfg, argv[++i])) {
                fprintf(stderr, "error: unknown preset '%s'\n", argv[i]);
                return 2;
            }
        } else if (!strcmp(a, "--width"))        { NEED_VALUE(a); cfg->width  = (uint32_t)strtoul(argv[++i], NULL, 10); cfg->preset = "custom"; }
        else if (!strcmp(a, "--height"))         { NEED_VALUE(a); cfg->height = (uint32_t)strtoul(argv[++i], NULL, 10); cfg->preset = "custom"; }
        else if (!strcmp(a, "--agents"))         { NEED_VALUE(a); cfg->agents = (uint32_t)strtoul(argv[++i], NULL, 10); cfg->preset = "custom"; }
        else if (!strcmp(a, "--ticks"))          { NEED_VALUE(a); cfg->ticks  = (uint32_t)strtoul(argv[++i], NULL, 10); }
        else if (!strcmp(a, "--warmup"))         { NEED_VALUE(a); cfg->warmup = (uint32_t)strtoul(argv[++i], NULL, 10); }
        else if (!strcmp(a, "--seed"))           { NEED_VALUE(a); cfg->seed   = (uint32_t)strtoul(argv[++i], NULL, 10); }
        else if (!strcmp(a, "--threads"))        { NEED_VALUE(a); cfg->threads = (uint32_t)strtoul(argv[++i], NULL, 10); }
        else if (!strcmp(a, "--hash-every"))     { NEED_VALUE(a); cfg->hash_every = (uint32_t)strtoul(argv[++i], NULL, 10); }
        else if (!strcmp(a, "--emit-chain"))     { NEED_VALUE(a); opt->emit_chain = argv[++i]; }
        else if (!strcmp(a, "--verify"))         { NEED_VALUE(a); opt->verify_chain = argv[++i]; }
        else if (!strcmp(a, "--sensor-steps"))   { NEED_VALUE(a); cfg->sensor_steps = (uint32_t)strtoul(argv[++i], NULL, 10); }
        else if (!strcmp(a, "--rot-steps"))      { NEED_VALUE(a); cfg->rot_steps = (uint32_t)strtoul(argv[++i], NULL, 10); }
        else if (!strcmp(a, "--sensor-dist"))    { NEED_VALUE(a); cfg->sensor_dist = strtof(argv[++i], NULL); }
        else if (!strcmp(a, "--step"))           { NEED_VALUE(a); cfg->step = strtof(argv[++i], NULL); }
        else if (!strcmp(a, "--deposit"))        { NEED_VALUE(a); cfg->deposit = strtof(argv[++i], NULL); }
        else if (!strcmp(a, "--decay"))          { NEED_VALUE(a); cfg->decay = strtof(argv[++i], NULL); }
        else if (!strcmp(a, "--display-max"))    { NEED_VALUE(a); opt->display_max = strtof(argv[++i], NULL); }
        else if (!strcmp(a, "--dump-grid"))      { NEED_VALUE(a); opt->dump_grid = argv[++i]; }
        else if (!strcmp(a, "--deposit-reduce")) {
            NEED_VALUE(a);
            const char *m = argv[++i];
            if (!strcmp(m, "private"))     cfg->reduce = SB_REDUCE_PRIVATE;
            else if (!strcmp(m, "binned")) cfg->reduce = SB_REDUCE_BINNED;
            else { fprintf(stderr, "error: --deposit-reduce must be private|binned\n"); return 2; }
        }
        else if (!strcmp(a, "--update")) {
            NEED_VALUE(a);
            const char *m = argv[++i];
            if (!strcmp(m, "serial"))        cfg->update = SB_UPDATE_SERIAL;
            else if (!strcmp(m, "deferred")) cfg->update = SB_UPDATE_DEFERRED;
            else { fprintf(stderr, "error: --update must be serial|deferred\n"); return 2; }
        }
        else if (!strcmp(a, "--headless"))   { opt->want_render = 0; }
        else if (!strcmp(a, "--render"))     { opt->want_render = 1; }
        else if (!strcmp(a, "--json"))       { opt->want_json = 1; }
        else if (!strcmp(a, "--freeze-sim")) { opt->freeze_sim = 1; }
        else if (!strcmp(a, "--simd"))       { cfg->simd = 1; }
        /* The agent pass, separately: it answers a different question from
         * the stencil and must not be folded into what class V measures. */
        else if (!strcmp(a, "--simd-agents")) { cfg->simd_agents = 1; }
        /* Spatial ordering of the agent arrays; the argument is how
         * many ticks between re-sorts. 0 keeps creation order. */
        else if (!strcmp(a, "--agent-tile")) {
            NEED_VALUE(a);
            cfg->agent_tile = (uint32_t)strtoul(argv[++i], NULL, 10);
        }
        else if (!strcmp(a, "--no-simd"))    { cfg->simd = 0; }
        else if (!strcmp(a, "--hud"))        { opt->want_hud = 1; }
        else if (!strcmp(a, "--no-hud"))     { opt->want_hud = 0; }
        else if (!strcmp(a, "--fullscreen")) { opt->fullscreen = 1; }
        else if (!strcmp(a, "--asm"))        { cfg->use_asm = 1; }
        else if (!strcmp(a, "--no-asm"))     { cfg->use_asm = 0; }
        else {
            /* SPEC-1 section 10: never silently ignore an unknown flag. */
            fprintf(stderr, "error: unknown argument '%s'\n", a);
            sb_print_usage(stderr, argv[0]);
            return 2;
        }
    }
    if (opt->want_hud < 0) opt->want_hud = !opt->want_json;
    if (cfg->use_asm) {
        if (cfg->simd) {
            fprintf(stderr, "error: --asm and --simd both choose the diffusion "
                            "kernel; pick one\n");
            return 2;
        }
        const char *why = NULL;
        if (!sb_asm_available(cfg, &why)) {
            fprintf(stderr, "error: --asm unavailable here: %s\n", why);
            return 2;
        }
    }
    if (cfg->agent_tile && cfg->update != SB_UPDATE_DEFERRED) {
        /* Same reason as --simd-agents: reordering the step is only sound
         * when no agent can read another's deposit within the tick. */
        fprintf(stderr, "error: --agent-tile requires --update deferred "
                        "(SPEC-1 5.5)\n");
        return 2;
    }
    if (cfg->simd_agents) {
        /* Refused rather than ignored. A flag that quietly does nothing is
         * how a measurement comes to be labelled as something it is not --
         * the same failure as a `--threads 1` that ran thirty-two. */
        if (cfg->update != SB_UPDATE_DEFERRED) {
            fprintf(stderr, "error: --simd-agents requires --update deferred: "
                            "in serial mode an agent reads deposits its "
                            "predecessors made this tick (SPEC-1 5.5)\n");
            return 2;
        }
        if (!sb_simd_agents_available()) {
            fprintf(stderr, "error: --simd-agents unavailable: this build has "
                            "no AVX-512 agent kernel\n");
            return 2;
        }
    }
    return 0;
}

static int cmp_double(const void *a, const void *b) {
    const double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}

void sb_emit_json(const sb_sim *s, const char *impl, const char *backend,
                  const char *cls, double ms_total,
                  const double *tick_ms, size_t n_ticks) {
    /* Class P interleaves the phases across threads, so the per-phase split
     * the serial path reports would be meaningless; emit it as zero there. */
    const int parallel = s->cfg.threads > 1;

    /* One field describing what actually ran: reduction strategy for class P,
     * and the vector ISA the diffusion pass was compiled for. */
    char variant[80];
    char tiled[24] = "";
    if (s->cfg.agent_tile)
        snprintf(tiled, sizeof tiled, "+tile%u", s->cfg.agent_tile);
    snprintf(variant, sizeof variant, "%s%s%s%s%s",
             parallel ? (s->cfg.reduce == SB_REDUCE_BINNED ? "binned" : "private")
                      : "scalar",
             s->cfg.use_asm ? "+" : (s->cfg.simd ? "+simd-" : ""),
             s->cfg.use_asm ? sb_asm_name() : (s->cfg.simd ? sb_simd_name() : ""),
             /* Named separately from the stencil: they are two kernels
              * answering two questions, and a row has to say which it used. */
             s->cfg.simd_agents ? "+simd-agents" : "",
             /* Spatial ordering changes which agent sits where, not what any
              * of them computes -- but it changes the number in the row, so
              * the row says so, with the interval it used. */
             tiled);
    double median = 0.0, p99 = 0.0, mean = 0.0;
    if (n_ticks > 0) {
        double *sorted = (double *)malloc(n_ticks * sizeof(double));
        memcpy(sorted, tick_ms, n_ticks * sizeof(double));
        qsort(sorted, n_ticks, sizeof(double), cmp_double);
        median = sorted[n_ticks / 2];
        size_t p99i = (size_t)((double)n_ticks * 0.99);
        if (p99i >= n_ticks) p99i = n_ticks - 1;
        p99 = sorted[p99i];
        for (size_t i = 0; i < n_ticks; i++) mean += tick_ms[i];
        mean /= (double)n_ticks;
        free(sorted);
    }

    const double cells = (double)s->cfg.width * (double)s->cfg.height;
    const double agent_updates = (double)s->cfg.agents * (double)n_ticks;
    const double cell_updates = cells * (double)n_ticks;
    const double maups = ms_total > 0 ? agent_updates / ms_total / 1000.0 : 0.0;
    const double mcups = ms_total > 0 ? cell_updates / ms_total / 1000.0 : 0.0;

    printf("{\"schema\":1,"
           "\"impl\":\"%s\",\"backend\":\"%s\",\"class\":\"%s\",\"preset\":\"%s\","
           "\"width\":%u,\"height\":%u,\"agents\":%u,\"ticks\":%zu,\"seed\":%u,"
           "\"update\":\"%s\",\"threads\":%u,\"variant\":\"%s\","
           "\"grid_hash\":\"0x%08X\",\"agent_hash\":\"0x%08X\",\"dirtable_hash\":\"0x%08X\","
           "\"ms_total\":%.4f,\"ms_agents\":%.4f,\"ms_diffuse\":%.4f,"
           "\"ms_per_tick_mean\":%.6f,\"ms_per_tick_median\":%.6f,\"ms_per_tick_p99\":%.6f,"
           "\"maups\":%.4f,\"mcups\":%.4f}\n",
           impl, backend, cls, s->cfg.preset,
           s->cfg.width, s->cfg.height, s->cfg.agents, n_ticks, s->cfg.seed,
           s->cfg.update == SB_UPDATE_DEFERRED ? "deferred" : "serial", s->cfg.threads,
           variant,
           sb_hash_grid(s), sb_hash_agents(s), sb_dirtable_hash(),
           ms_total,
           parallel ? 0.0 : (double)s->ns_agents / 1e6,
           parallel ? 0.0 : (double)s->ns_diffuse / 1e6,
           mean, median, p99, maups, mcups);
}

int sb_dump_grid(const sb_sim *s, const char *path) {
    FILE *f = fopen(path, "wb");
    if (!f) return 1;
    const size_t cells = (size_t)s->cfg.width * s->cfg.height;
    const size_t n = fwrite(s->grid, sizeof(float), cells, f);
    fclose(f);
    return n == cells ? 0 : 1;
}
