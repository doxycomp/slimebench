#include "sb_cli.h"

#include <stdlib.h>
#include <string.h>

void sb_print_usage(FILE *f, const char *argv0) {
    fprintf(f,
        "usage: %s [options]   (slimebench " SB_SPEC_VERSION ")\n"
        "  --preset NAME        tiny|small|medium|large|browser\n"
        "  --width N --height N powers of two\n"
        "  --agents N  --ticks N  --warmup N  --seed N\n"
        "  --update MODE        serial|deferred\n"
        "  --threads N\n"
        "  --sensor-dist F  --sensor-steps N  --rot-steps N\n"
        "  --step F  --deposit F  --decay F\n"
        "  --headless  --render  --freeze-sim\n"
        "  --json  --hash-every N  --dump-grid PATH  --display-max F\n"
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
        else if (!strcmp(a, "--sensor-steps"))   { NEED_VALUE(a); cfg->sensor_steps = (uint32_t)strtoul(argv[++i], NULL, 10); }
        else if (!strcmp(a, "--rot-steps"))      { NEED_VALUE(a); cfg->rot_steps = (uint32_t)strtoul(argv[++i], NULL, 10); }
        else if (!strcmp(a, "--sensor-dist"))    { NEED_VALUE(a); cfg->sensor_dist = strtof(argv[++i], NULL); }
        else if (!strcmp(a, "--step"))           { NEED_VALUE(a); cfg->step = strtof(argv[++i], NULL); }
        else if (!strcmp(a, "--deposit"))        { NEED_VALUE(a); cfg->deposit = strtof(argv[++i], NULL); }
        else if (!strcmp(a, "--decay"))          { NEED_VALUE(a); cfg->decay = strtof(argv[++i], NULL); }
        else if (!strcmp(a, "--display-max"))    { NEED_VALUE(a); opt->display_max = strtof(argv[++i], NULL); }
        else if (!strcmp(a, "--dump-grid"))      { NEED_VALUE(a); opt->dump_grid = argv[++i]; }
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
        else {
            /* SPEC-1 section 10: never silently ignore an unknown flag. */
            fprintf(stderr, "error: unknown argument '%s'\n", a);
            sb_print_usage(stderr, argv[0]);
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
           "\"update\":\"%s\",\"threads\":%u,"
           "\"grid_hash\":\"0x%08X\",\"agent_hash\":\"0x%08X\",\"dirtable_hash\":\"0x%08X\","
           "\"ms_total\":%.4f,\"ms_agents\":%.4f,\"ms_diffuse\":%.4f,"
           "\"ms_per_tick_mean\":%.6f,\"ms_per_tick_median\":%.6f,\"ms_per_tick_p99\":%.6f,"
           "\"maups\":%.4f,\"mcups\":%.4f}\n",
           impl, backend, cls, s->cfg.preset,
           s->cfg.width, s->cfg.height, s->cfg.agents, n_ticks, s->cfg.seed,
           s->cfg.update == SB_UPDATE_DEFERRED ? "deferred" : "serial", s->cfg.threads,
           sb_hash_grid(s), sb_hash_agents(s), sb_dirtable_hash(),
           ms_total, (double)s->ns_agents / 1e6, (double)s->ns_diffuse / 1e6,
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
