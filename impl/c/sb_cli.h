/* Shared CLI parsing and result reporting (SPEC-1 section 10). */
#ifndef SB_CLI_H
#define SB_CLI_H

#include <stdio.h>
#include "sb_core.h"

typedef struct {
    int want_render;      /* --render */
    int want_json;        /* --json   */
    /* Render benchmarks only: keep re-uploading the same grid so the
     * measurement is the upload path, not the simulation (SPEC-1 11.1). */
    int freeze_sim;       /* --freeze-sim */
    const char *dump_grid;
    float display_max;
} sb_cli_opts;

/* Returns 0 on success, 2 on a usage error (message already on stderr). */
int sb_parse_args(int argc, char **argv, sb_config *cfg, sb_cli_opts *opt);

void sb_print_usage(FILE *f, const char *argv0);

/* Emits the single-line result JSON on stdout (SPEC-1 section 10.1). */
void sb_emit_json(const sb_sim *s, const char *impl, const char *backend,
                  const char *cls, double ms_total,
                  const double *tick_ms, size_t n_ticks);

int sb_dump_grid(const sb_sim *s, const char *path);

#endif /* SB_CLI_H */
