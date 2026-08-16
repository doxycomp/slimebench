/* Shared render-timing helper for the windowed C frontends (SPEC-1 11.1).
 *
 * A rendering backend benchmark measures the upload path
 * grid -> texture -> screen. If the simulation keeps running during the
 * measurement it dominates the frame and the backends come out
 * indistinguishable, so --freeze-sim stops it and every frame re-uploads the
 * same grid.
 */
#ifndef SB_RENDER_H
#define SB_RENDER_H

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "sb_core.h"

typedef struct {
    double *ms;
    size_t n, cap;
    size_t since_title;
} sb_render_stats;

static inline void sb_rs_init(sb_render_stats *s, size_t cap) {
    s->ms = (double *)malloc(cap * sizeof(double));
    s->n = 0;
    s->cap = cap;
    s->since_title = 0;
}

static inline void sb_rs_free(sb_render_stats *s) { free(s->ms); }

static inline void sb_rs_add(sb_render_stats *s, uint64_t ns) {
    if (s->n < s->cap) s->ms[s->n++] = (double)ns / 1e6;
    s->since_title++;
}

/* Mean of the last k frames, for the window title. */
static inline double sb_rs_recent_mean(const sb_render_stats *s, size_t k) {
    if (s->n == 0) return 0.0;
    const size_t take = k < s->n ? k : s->n;
    double sum = 0.0;
    for (size_t i = s->n - take; i < s->n; i++) sum += s->ms[i];
    return sum / (double)take;
}

static int sb_cmp_double_r(const void *a, const void *b) {
    const double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}

static inline void sb_rs_emit_json(const sb_render_stats *s, const sb_sim *sim,
                                   const char *impl, const char *backend) {
    if (s->n == 0) return;
    double *sorted = (double *)malloc(s->n * sizeof(double));
    memcpy(sorted, s->ms, s->n * sizeof(double));
    qsort(sorted, s->n, sizeof(double), sb_cmp_double_r);

    double mean = 0.0;
    for (size_t i = 0; i < s->n; i++) mean += s->ms[i];
    mean /= (double)s->n;

    const double median = sorted[s->n / 2];
    size_t p99i = (size_t)((double)s->n * 0.99);
    if (p99i >= s->n) p99i = s->n - 1;
    const double p99 = sorted[p99i];
    const double mpix = (double)sim->cfg.width * (double)sim->cfg.height / 1e6;
    free(sorted);

    printf("{\"schema\":1,\"impl\":\"%s\",\"backend\":\"%s\",\"class\":\"R\","
           "\"preset\":\"%s\",\"width\":%u,\"height\":%u,\"frames\":%zu,"
           "\"ms_render_mean\":%.6f,\"ms_render_median\":%.6f,"
           "\"ms_render_p99\":%.6f,\"fps_equiv\":%.2f,\"mpixels_per_s\":%.1f}\n",
           impl, backend, sim->cfg.preset, sim->cfg.width, sim->cfg.height, s->n,
           mean, median, p99,
           median > 0 ? 1000.0 / median : 0.0,
           median > 0 ? mpix * 1000.0 / median : 0.0);
}

#endif /* SB_RENDER_H */
