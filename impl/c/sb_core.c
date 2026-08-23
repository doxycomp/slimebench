/* slimebench -- C reference implementation of SPEC-1. */

#include "sb_core.h"
#include "sb_agent.h"
#include "sb_simd.h"
#include "sb_asm.h"

#include <float.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

/* SPEC-1 section 1.2 rule 5: no extended intermediate precision. */
#if defined(FLT_EVAL_METHOD) && FLT_EVAL_METHOD != 0
#error "FLT_EVAL_METHOD must be 0 (SSE math). x87 breaks bit-exactness."
#endif

#define SB_FNV_OFFSET 0x811C9DC5u
#define SB_FNV_PRIME  0x01000193u

/* ---- bit casts ---------------------------------------------------------- */

static inline float bits_to_f32(uint32_t b) {
    float f;
    memcpy(&f, &b, sizeof f);
    return f;
}

static inline uint32_t f32_to_bits(float f) {
    uint32_t b;
    memcpy(&b, &f, sizeof b);
    return b;
}

/* wrapf, the PRNG and the per-agent step live in sb_agent.h / sb_core.h so
 * the threaded tick in sb_parallel.c runs the identical code. */

/* ---- setup -------------------------------------------------------------- */

#if defined(SB_BRANCH_STATS) && SB_BRANCH_STATS
#include <stdio.h>
/* Storage and report for the counters declared in sb_agent.h; see the comment
   there for why they are compiled out by default. */
uint64_t sb_branch_tally[4];

void sb_branch_report(void) {
    static const char *name[4] = {"straight", "dead-end", "turn-left", "turn-right"};
    uint64_t total = 0;
    for (int i = 0; i < 4; i++) total += sb_branch_tally[i];
    if (total == 0) return;
    fprintf(stderr, "branch_stats total=%llu", (unsigned long long)total);
    for (int i = 0; i < 4; i++)
        fprintf(stderr, " %s=%.2f%%", name[i],
                100.0 * (double)sb_branch_tally[i] / (double)total);
    fprintf(stderr, "\n");
}
#endif

void sb_config_defaults(sb_config *c) {
    memset(c, 0, sizeof *c);
    c->width = 1024;
    c->height = 1024;
    c->agents = 262144;
    c->ticks = 1000;
    c->warmup = 0;
    c->seed = 12345;
    c->threads = 1;
    c->update = SB_UPDATE_SERIAL;
    c->sensor_dist = 9.0f;
    c->step = 1.0f;
    c->deposit = 10.0f;
    c->decay = 0.94f;
    c->sensor_steps = 144;
    c->rot_steps = 144;
    c->hash_every = 0;
    c->preset = "custom";
}

static uint32_t log2_exact(uint32_t v) {
    uint32_t n = 0;
    while ((1u << n) < v) n++;
    return n;
}

int sb_sim_init(sb_sim *s, const sb_config *cfg) {
    memset(s, 0, sizeof *s);
    s->cfg = *cfg;

    if (cfg->width == 0 || (cfg->width & (cfg->width - 1)) != 0) return 1;
    if (cfg->height == 0 || (cfg->height & (cfg->height - 1)) != 0) return 1;

    s->cfg.log2w = log2_exact(cfg->width);
    s->cfg.log2h = log2_exact(cfg->height);

    for (uint32_t d = 0; d < SB_NDIR; d++) {
        s->cos_tab[d] = bits_to_f32(SB_COS_BITS[d]);
        s->sin_tab[d] = bits_to_f32(SB_SIN_BITS[d]);
        /* Interleaved and pre-scaled; see the comment on sens_tab. Exactly
         * the multiply the scalar step performs, hoisted out of the loop. */
        s->sens_tab[d * 2 + 0] = s->cos_tab[d] * cfg->sensor_dist;
        s->sens_tab[d * 2 + 1] = s->sin_tab[d] * cfg->sensor_dist;
        s->move_tab[d * 2 + 0] = s->cos_tab[d] * cfg->step;
        s->move_tab[d * 2 + 1] = s->sin_tab[d] * cfg->step;
    }

    const size_t cells = (size_t)cfg->width * cfg->height;
    s->grid    = (float *)malloc(cells * sizeof(float));
    s->scratch = (float *)malloc(cells * sizeof(float));
    s->dep     = (cfg->update == SB_UPDATE_DEFERRED)
                     ? (float *)calloc(cells, sizeof(float)) : NULL;
    s->ax   = (float *)malloc((size_t)cfg->agents * sizeof(float));
    s->ay   = (float *)malloc((size_t)cfg->agents * sizeof(float));
    s->adir = (uint16_t *)malloc((size_t)cfg->agents * sizeof(uint16_t));
    s->arng = (uint32_t *)malloc((size_t)cfg->agents * 4 * sizeof(uint32_t));
    const int buffered = cfg->simd_agents || cfg->agent_tile;
    s->agent_idx = buffered
                 ? (uint32_t *)malloc((size_t)cfg->agents * sizeof(uint32_t))
                 : NULL;
    if (cfg->agent_tile) {
        const size_t n = cfg->agents;
        s->aid          = (uint32_t *)malloc(n * sizeof(uint32_t));
        s->slot         = (uint32_t *)malloc(n * sizeof(uint32_t));
        s->sort_scratch = (uint32_t *)malloc(n * sizeof(uint32_t));
        s->sort_f32     = (float *)malloc(n * sizeof(float));
        s->sort_u32     = (uint32_t *)malloc(n * 4 * sizeof(uint32_t));
        s->sort_u16     = (uint16_t *)malloc(n * sizeof(uint16_t));
        for (uint32_t i = 0; i < cfg->agents; i++) {
            s->aid[i] = i;
            s->slot[i] = i;
        }
    }

    if (!s->grid || !s->scratch || !s->ax || !s->ay || !s->adir || !s->arng ||
        (cfg->update == SB_UPDATE_DEFERRED && !s->dep) ||
        (buffered && !s->agent_idx) ||
        (cfg->agent_tile && (!s->aid || !s->slot || !s->sort_scratch ||
                             !s->sort_f32 || !s->sort_u32 || !s->sort_u16))) {
        sb_sim_free(s);
        return 2;
    }

    /* Grid init: its own SplitMix32 stream (SPEC-1 section 3.3). */
    uint32_t sm = cfg->seed ^ 0x5BF03635u;
    for (size_t i = 0; i < cells; i++) {
        s->grid[i] = sb_rnd01(sb_splitmix32(&sm)) * 100.0f;
    }

    /* Agent init: one independent stream per agent, so this is order-free. */
    const float fw = (float)cfg->width;
    const float fh = (float)cfg->height;
    for (uint32_t i = 0; i < cfg->agents; i++) {
        uint32_t asm_ = cfg->seed + 0x9E3779B9u * (i + 1u);
        uint32_t *r = &s->arng[(size_t)i * 4];
        r[0] = sb_splitmix32(&asm_);
        r[1] = sb_splitmix32(&asm_);
        r[2] = sb_splitmix32(&asm_);
        r[3] = sb_splitmix32(&asm_);
        if ((r[0] | r[1] | r[2] | r[3]) == 0u) r[0] = 1u;

        s->ax[i] = sb_rnd01(sb_xoshiro128pp(r)) * fw;
        s->ay[i] = sb_rnd01(sb_xoshiro128pp(r)) * fh;
        s->adir[i] = (uint16_t)(sb_xoshiro128pp(r) % SB_NDIR);
    }

    return 0;
}

void sb_sim_free(sb_sim *s) {
    free(s->grid);
    free(s->scratch);
    free(s->dep);
    free(s->ax);
    free(s->ay);
    free(s->adir);
    free(s->arng);
    free(s->agent_idx);
    free(s->aid);
    free(s->slot);
    free(s->sort_scratch);
    free(s->sort_f32);
    free(s->sort_u32);
    free(s->sort_u16);
    memset(s, 0, sizeof *s);
}

/* ---- spatial agent ordering ---------------------------------------------
 *
 * A counting sort of the agent arrays into tiles of the grid, so that the
 * sixteen lanes of a sensor gather land in a few cache lines instead of
 * sixteen unrelated ones.
 *
 * Row-major cell order would only help along x: with sensor_dist near 9 and a
 * 2048-wide grid, the three sensors of one agent span nine rows, which is
 * 73 KiB apart. Tiles put the neighbourhood in the array neighbourhood.
 *
 * The tile size is measured, not reasoned about. `medium`, vectorised agent
 * pass, re-sorting every second tick, milliseconds in the agent pass:
 *
 *     1x1   434      16x16  336
 *     2x2   368      32x32  467
 *     4x4   334      64x64  505
 *     8x8   317     128x128 489
 *
 * Small wins, and 1x1 -- an exact sort by cell -- loses again because the
 * counting sort's histogram becomes one entry per cell, 4.19 million of them.
 * 8x8 it is. At that size the re-sort interval barely matters either: every
 * tick and every eight ticks are 320 and 326 ms, so the sort is cheap enough
 * that how often it runs is not the interesting parameter.
 *
 * What this does not change: any agent's arithmetic, any agent's PRNG stream
 * (the state moves with the agent), or the order deposits are applied in --
 * the pass writes each cell to agent_idx[original index] and the deposit loop
 * walks that array from 0. The grid hash and the agent hash are therefore the
 * same as without ordering, which is the claim, and the conformance gate is
 * what checks it.
 */
#define SB_TILE_SHIFT 3u          /* 8x8 cells; see the table above */

static void sb_agent_sort(sb_sim *s) {
    const uint32_t n = s->cfg.agents;
    const uint32_t tw = (s->cfg.width + (1u << SB_TILE_SHIFT) - 1u)
                        >> SB_TILE_SHIFT;
    const uint32_t th = (s->cfg.height + (1u << SB_TILE_SHIFT) - 1u)
                        >> SB_TILE_SHIFT;
    const uint32_t ntiles = tw * th;

    uint32_t *count = (uint32_t *)calloc((size_t)ntiles + 1u, sizeof(uint32_t));
    if (!count) return;           /* ordering is an optimisation; skip it */

    const uint32_t xmask = s->cfg.width - 1u;
    const uint32_t ymask = s->cfg.height - 1u;

    uint32_t *key = s->sort_scratch;
    for (uint32_t j = 0; j < n; j++) {
        const uint32_t x = (uint32_t)s->ax[j] & xmask;
        const uint32_t y = (uint32_t)s->ay[j] & ymask;
        key[j] = (y >> SB_TILE_SHIFT) * tw + (x >> SB_TILE_SHIFT);
        count[key[j] + 1u]++;
    }
    for (uint32_t t = 0; t < ntiles; t++) count[t + 1u] += count[t];

    /* count[] now holds the first output slot of each tile; walking the
     * agents in their current order keeps the sort stable, which keeps a
     * re-sort cheap when almost nothing has moved. */
    for (uint32_t j = 0; j < n; j++) {
        const uint32_t dst = count[key[j]]++;
        s->sort_f32[dst] = s->ax[j];
        s->sort_u16[dst] = s->adir[j];
        s->sort_u32[(size_t)dst * 4 + 0] = s->arng[(size_t)j * 4 + 0];
        s->sort_u32[(size_t)dst * 4 + 1] = s->arng[(size_t)j * 4 + 1];
        s->sort_u32[(size_t)dst * 4 + 2] = s->arng[(size_t)j * 4 + 2];
        s->sort_u32[(size_t)dst * 4 + 3] = s->arng[(size_t)j * 4 + 3];
        /* ay goes in the second pass; one staging buffer, two uses. */
        key[j] = dst;
    }
    memcpy(s->ax, s->sort_f32, (size_t)n * sizeof(float));
    memcpy(s->adir, s->sort_u16, (size_t)n * sizeof(uint16_t));
    memcpy(s->arng, s->sort_u32, (size_t)n * 4 * sizeof(uint32_t));
    for (uint32_t j = 0; j < n; j++) s->sort_f32[key[j]] = s->ay[j];
    memcpy(s->ay, s->sort_f32, (size_t)n * sizeof(float));

    /* aid follows the same permutation, and slot is its inverse. */
    uint32_t *newaid = (uint32_t *)s->sort_u32;   /* reused, already copied */
    for (uint32_t j = 0; j < n; j++) newaid[key[j]] = s->aid[j];
    memcpy(s->aid, newaid, (size_t)n * sizeof(uint32_t));
    for (uint32_t j = 0; j < n; j++) s->slot[s->aid[j]] = j;

    free(count);
}

/* ---- agent pass (SPEC-1 section 5.3) ------------------------------------ */

static void sb_agent_pass(sb_sim *s) {
    const sb_agent_ctx k = sb_agent_ctx_make(s);
    const float deposit = s->cfg.deposit;
    float *target = (s->cfg.update == SB_UPDATE_DEFERRED) ? s->dep : s->grid;

    /* The buffered path: step every agent, then apply the deposits.
     *
     * Used by the vectorised kernel, which cannot deposit as it goes, and by
     * spatial ordering, where the step order is no longer the agent order.
     * Only in `deferred` mode: `serial` lets an agent read a deposit its
     * predecessor made this tick, and neither a vector of sixteen nor a
     * reordered array can express that.
     *
     * The deposits are applied scalar, in ascending *agent* index -- the same
     * order, and therefore the same floats, as the direct loop below. That is
     * what makes both of these bit-identical to it. */
    if (s->agent_idx) {
        const uint32_t n = s->cfg.agents;
        if (s->cfg.simd_agents) {
            sb_simd_agents(s, 0, n, s->agent_idx);
        } else {
            for (uint32_t j = 0; j < n; j++) {
                const uint32_t cell = sb_agent_step(&k, s, j);
                s->agent_idx[s->aid ? s->aid[j] : j] = cell;
            }
        }
        for (uint32_t i = 0; i < n; i++) {
            const uint32_t idx = s->agent_idx[i];
            target[idx] = target[idx] + deposit;
        }
        return;
    }

    for (uint32_t i = 0; i < s->cfg.agents; i++) {
        const uint32_t idx = sb_agent_step(&k, s, i);
        target[idx] = target[idx] + deposit;
    }
}

/* ---- diffusion + decay (SPEC-1 section 5.4) ----------------------------- */

static void sb_diffuse_pass(sb_sim *s) {
    if (s->cfg.use_asm)
        sb_diffuse_rows_asm(s, s->grid, s->scratch, 0, s->cfg.height);
    else if (s->cfg.simd)
        sb_diffuse_rows_simd(s, s->grid, s->scratch, 0, s->cfg.height);
    else
        sb_diffuse_rows(s, s->grid, s->scratch, 0, s->cfg.height);
    float *tmp = s->grid;
    s->grid = s->scratch;
    s->scratch = tmp;
}

void sb_tick(sb_sim *s) {
    /* Re-sort inside the timed region, not beside it: the ordering is only
     * worth having if it pays for itself, and a cost measured somewhere else
     * is not a cost. Every `agent_tile` ticks, starting with the first. */
    if (s->cfg.agent_tile && s->ticks_done % s->cfg.agent_tile == 0)
        sb_agent_sort(s);
    s->ticks_done++;

    uint64_t t0 = sb_now_ns();
    sb_agent_pass(s);
    uint64_t t1 = sb_now_ns();

    if (s->cfg.update == SB_UPDATE_DEFERRED) {
        const size_t cells = (size_t)s->cfg.width * s->cfg.height;
        for (size_t i = 0; i < cells; i++) {
            s->grid[i] = s->grid[i] + s->dep[i];
            s->dep[i] = 0.0f;
        }
    }

    sb_diffuse_pass(s);
    uint64_t t2 = sb_now_ns();

    s->ns_agents += t1 - t0;
    s->ns_diffuse += t2 - t1;
}

/* ---- checksums (SPEC-1 section 6) --------------------------------------- */

static inline uint32_t fnv_step(uint32_t h, uint32_t word) {
    return (h ^ word) * SB_FNV_PRIME;
}

uint32_t sb_hash_grid(const sb_sim *s) {
    const size_t cells = (size_t)s->cfg.width * s->cfg.height;
    uint32_t h = SB_FNV_OFFSET;
    for (size_t i = 0; i < cells; i++) h = fnv_step(h, f32_to_bits(s->grid[i]));
    return h;
}

uint32_t sb_hash_agents(const sb_sim *s) {
    uint32_t h = SB_FNV_OFFSET;
    /* In agent order, which is slot order only when the arrays have not been
     * spatially re-sorted. Hashing slots instead would make the checksum
     * depend on a performance decision, which is the one thing it must not
     * do -- the whole point of SPEC-1 6.3 is that the number identifies the
     * computation and nothing else. */
    for (uint32_t a = 0; a < s->cfg.agents; a++) {
        const uint32_t i = s->slot ? s->slot[a] : a;
        h = fnv_step(h, f32_to_bits(s->ax[i]));
        h = fnv_step(h, f32_to_bits(s->ay[i]));
        h = fnv_step(h, (uint32_t)s->adir[i]);
    }
    return h;
}

uint32_t sb_dirtable_hash(void) {
    uint32_t h = SB_FNV_OFFSET;
    for (uint32_t d = 0; d < SB_NDIR; d++) h = fnv_step(h, SB_COS_BITS[d]);
    for (uint32_t d = 0; d < SB_NDIR; d++) h = fnv_step(h, SB_SIN_BITS[d]);
    return h;
}

/* ---- misc --------------------------------------------------------------- */

uint64_t sb_now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

void sb_render_gray(const sb_sim *s, uint8_t *out, float display_max) {
    const size_t cells = (size_t)s->cfg.width * s->cfg.height;
    const float scale = 255.0f / display_max;
    for (size_t i = 0; i < cells; i++) {
        int v = (int)(s->grid[i] * scale);
        if (v < 0) v = 0;
        if (v > 255) v = 255;
        out[i] = (uint8_t)v;
    }
}
