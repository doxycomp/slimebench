/* slimebench -- C reference implementation of SPEC-1.
 *
 * This file is the normative reference the other seven languages are ported
 * from and verified against. Keep it boring and literal: every deviation from
 * spec/SPEC.md, however clever, is a bug.
 */
#ifndef SB_CORE_H
#define SB_CORE_H

#include <stdint.h>
#include <stddef.h>

#include "dirtable.h"

#define SB_SPEC_VERSION "SPEC-1"

typedef enum { SB_UPDATE_SERIAL = 0, SB_UPDATE_DEFERRED = 1 } sb_update_mode;

/* SPEC-1 section 5.6. `private` is reproducible per thread count; `binned` is
 * bit-identical to a single-threaded run for any thread count. */
typedef enum { SB_REDUCE_PRIVATE = 0, SB_REDUCE_BINNED = 1 } sb_reduce_mode;

typedef struct {
    uint32_t width, height;   /* powers of two */
    uint32_t log2w, log2h;
    uint32_t agents;
    uint32_t ticks;
    uint32_t warmup;
    uint32_t seed;
    uint32_t threads;
    sb_update_mode update;
    sb_reduce_mode reduce;
    int simd;                 /* class V: vectorised diffusion pass */
    int use_asm;              /* class V: hand-written assembly kernel */
    int simd_agents;          /* vectorised agent pass; deferred only */
    /* Ticks between spatial re-sorts of the agent arrays; 0 = never.
     * See sb_agent_sort() -- this changes which agent sits where, not
     * what any of them computes. */
    uint32_t agent_tile;

    float sensor_dist;
    float step;
    float deposit;
    float decay;
    uint32_t sensor_steps;
    uint32_t rot_steps;

    uint32_t hash_every;      /* 0 = off */
    const char *preset;
} sb_config;

typedef struct {
    sb_config cfg;

    float *grid;              /* width*height */
    float *scratch;           /* width*height, diffusion target */
    float *dep;               /* width*height, only for SB_UPDATE_DEFERRED */

    /* Agents, struct-of-arrays: the layout the SIMD and GPU tiers will want. */
    float    *ax;
    float    *ay;
    uint16_t *adir;
    uint32_t *arng;           /* 4 words per agent */
    /* One target cell per agent, filled by the agent pass so the deposits
     * can be applied afterwards in ascending agent order. Allocated when
     * either the vector path or spatial ordering is on -- both need the
     * deposit separated from the step. */
    uint32_t *agent_idx;

    /* Spatial ordering (cfg.agent_tile). `aid[j]` is the original index of
     * the agent now in slot j, and `slot[a]` is the inverse. Everything that
     * has to speak in agent indices rather than slots -- the deposit, the
     * agent hash -- goes through one of them. NULL when ordering is off, and
     * every path checks for that rather than paying an indirection it does
     * not need. */
    uint32_t *aid;
    uint32_t *slot;
    uint32_t *sort_scratch;   /* tile histogram, then the permutation */
    float    *sort_f32;       /* staging for ax/ay during the permute */
    uint32_t *sort_u32;       /* staging for arng */
    uint16_t *sort_u16;       /* staging for adir */
    uint32_t  ticks_done;     /* drives the re-sort interval */

    /* The same trig values, multiplied by the two distances the tick uses and
     * interleaved as (x, y) pairs.
     *
     * Bit-identical to computing cos_tab[d] * sensor_dist in the loop -- same
     * two operands, same multiply, done once instead of a million times a
     * tick -- and the pairing lets a vector kernel fetch both components of a
     * direction in one eight-byte gather element instead of two four-byte
     * ones. That halves the load-port traffic of the eight table gathers the
     * agent step needs, which measurement puts at 54 % of its time.
     *
     * Built in sb_sim_init after cos_tab and sin_tab, used by
     * sb_simd_agents.c and impl/asm/sb_agents_avx512.S. The scalar path does
     * not read them: it must keep doing the multiply where SPEC-1 5.3 puts
     * it, so that the two paths can be compared rather than assumed equal. */
    float sens_tab[SB_NDIR * 2];   /* cos*sensor_dist, sin*sensor_dist */
    float move_tab[SB_NDIR * 2];   /* cos*step,        sin*step        */

    float cos_tab[SB_NDIR];
    float sin_tab[SB_NDIR];

    /* Accumulated timings, nanoseconds. */
    uint64_t ns_agents;
    uint64_t ns_diffuse;
} sb_sim;

/* ---- PRNG (SPEC-1 section 3.1) ------------------------------------------
 *
 * In the header because the agent step in sb_agent.h is shared between the
 * serial and the threaded tick and must inline it in both.
 */

static inline uint32_t sb_rotl32(uint32_t x, int k) {
    return (uint32_t)((x << k) | (x >> (32 - k)));
}

static inline uint32_t sb_splitmix32(uint32_t *state) {
    uint32_t z = (*state += 0x9E3779B9u);
    z = (z ^ (z >> 16)) * 0x21F0AAADu;
    z = (z ^ (z >> 15)) * 0x735A2D97u;
    return z ^ (z >> 15);
}

static inline uint32_t sb_xoshiro128pp(uint32_t *s) {
    const uint32_t result = sb_rotl32(s[0] + s[3], 7) + s[0];
    const uint32_t t = s[1] << 9;
    s[2] ^= s[0];
    s[3] ^= s[1];
    s[1] ^= s[2];
    s[0] ^= s[3];
    s[2] ^= t;
    s[3] = sb_rotl32(s[3], 11);
    return result;
}

/* SPEC-1 section 3.2. Exact in f32: (u>>8) < 2^24 and 2^24 is a power of two. */
static inline float sb_rnd01(uint32_t u) {
    return (float)(u >> 8) / 16777216.0f;
}

/* ---- lifecycle ---------------------------------------------------------- */

void sb_config_defaults(sb_config *c);
/* Returns 0 on success. Fills the sim according to SPEC-1 section 3.3. */
int  sb_sim_init(sb_sim *s, const sb_config *cfg);
void sb_sim_free(sb_sim *s);

/* One full tick: agent pass then diffusion/decay pass (SPEC-1 section 5.2). */
void sb_tick(sb_sim *s);

/* ---- checksums (SPEC-1 section 6) --------------------------------------- */

uint32_t sb_hash_grid(const sb_sim *s);
uint32_t sb_hash_agents(const sb_sim *s);
uint32_t sb_dirtable_hash(void);

/* ---- misc --------------------------------------------------------------- */

uint64_t sb_now_ns(void);
/* Writes W*H bytes of greyscale (SPEC-1 section 11) into `out`. */
#if defined(SB_BRANCH_STATS) && SB_BRANCH_STATS
/* Prints how the agent pass's four-way turn decision split, to stderr.
   Only compiled when the build asked for it -- see sb_agent.h. */
void sb_branch_report(void);
#endif

void sb_render_gray(const sb_sim *s, uint8_t *out, float display_max);

#endif /* SB_CORE_H */
