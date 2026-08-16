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

typedef struct {
    uint32_t width, height;   /* powers of two */
    uint32_t log2w, log2h;
    uint32_t agents;
    uint32_t ticks;
    uint32_t warmup;
    uint32_t seed;
    uint32_t threads;
    sb_update_mode update;

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

    float cos_tab[SB_NDIR];
    float sin_tab[SB_NDIR];

    /* Accumulated timings, nanoseconds. */
    uint64_t ns_agents;
    uint64_t ns_diffuse;
} sb_sim;

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
void sb_render_gray(const sb_sim *s, uint8_t *out, float display_max);

#endif /* SB_CORE_H */
