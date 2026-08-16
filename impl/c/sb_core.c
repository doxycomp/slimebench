/* slimebench -- C reference implementation of SPEC-1. */

#include "sb_core.h"

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

/* ---- PRNG (SPEC-1 section 3.1) ------------------------------------------ */

static inline uint32_t rotl32(uint32_t x, int k) {
    return (uint32_t)((x << k) | (x >> (32 - k)));
}

static inline uint32_t splitmix32(uint32_t *state) {
    uint32_t z = (*state += 0x9E3779B9u);
    z = (z ^ (z >> 16)) * 0x21F0AAADu;
    z = (z ^ (z >> 15)) * 0x735A2D97u;
    return z ^ (z >> 15);
}

static inline uint32_t xoshiro128pp(uint32_t *s) {
    const uint32_t result = rotl32(s[0] + s[3], 7) + s[0];
    const uint32_t t = s[1] << 9;
    s[2] ^= s[0];
    s[3] ^= s[1];
    s[1] ^= s[2];
    s[0] ^= s[3];
    s[2] ^= t;
    s[3] = rotl32(s[3], 11);
    return result;
}

/* SPEC-1 section 3.2. Exact in f32: (u>>8) < 2^24 and 2^24 is a power of two. */
static inline float rnd01(uint32_t u) {
    return (float)(u >> 8) / 16777216.0f;
}

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

/* ---- wrapping (SPEC-1 section 2.2) -------------------------------------- */

static inline float wrapf(float v, float m) {
    if (v < 0.0f) v = v + m;
    if (v >= m)   v = v - m;
    return v;
}

/* ---- setup -------------------------------------------------------------- */

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

    if (!s->grid || !s->scratch || !s->ax || !s->ay || !s->adir || !s->arng ||
        (cfg->update == SB_UPDATE_DEFERRED && !s->dep)) {
        sb_sim_free(s);
        return 2;
    }

    /* Grid init: its own SplitMix32 stream (SPEC-1 section 3.3). */
    uint32_t sm = cfg->seed ^ 0x5BF03635u;
    for (size_t i = 0; i < cells; i++) {
        s->grid[i] = rnd01(splitmix32(&sm)) * 100.0f;
    }

    /* Agent init: one independent stream per agent, so this is order-free. */
    const float fw = (float)cfg->width;
    const float fh = (float)cfg->height;
    for (uint32_t i = 0; i < cfg->agents; i++) {
        uint32_t asm_ = cfg->seed + 0x9E3779B9u * (i + 1u);
        uint32_t *r = &s->arng[(size_t)i * 4];
        r[0] = splitmix32(&asm_);
        r[1] = splitmix32(&asm_);
        r[2] = splitmix32(&asm_);
        r[3] = splitmix32(&asm_);
        if ((r[0] | r[1] | r[2] | r[3]) == 0u) r[0] = 1u;

        s->ax[i] = rnd01(xoshiro128pp(r)) * fw;
        s->ay[i] = rnd01(xoshiro128pp(r)) * fh;
        s->adir[i] = (uint16_t)(xoshiro128pp(r) % SB_NDIR);
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
    memset(s, 0, sizeof *s);
}

/* ---- agent pass (SPEC-1 section 5.3) ------------------------------------ */

/* Grid geometry hoisted out of the hot loop; passed by value so the compiler
 * keeps it all in registers. */
typedef struct {
    const float *grid;
    const float *cos_tab;
    const float *sin_tab;
    float fw, fh, sdist;
    uint32_t xmask, ymask, log2w;
} sb_sense_ctx;

static inline float sb_sense(const sb_sense_ctx *k, float x, float y, int d) {
    const float sx = wrapf(x + k->cos_tab[d] * k->sdist, k->fw);
    const float sy = wrapf(y + k->sin_tab[d] * k->sdist, k->fh);
    return k->grid[(((uint32_t)sy & k->ymask) << k->log2w) |
                   ((uint32_t)sx & k->xmask)];
}

static void sb_agent_pass(sb_sim *s) {
    const sb_config *c = &s->cfg;
    const uint32_t xmask = c->width - 1u;
    const uint32_t ymask = c->height - 1u;
    const uint32_t log2w = c->log2w;
    const float fw = (float)c->width;
    const float fh = (float)c->height;
    const float sdist = c->sensor_dist;
    const float step = c->step;
    const float deposit = c->deposit;
    const int ss = (int)c->sensor_steps;
    const int rs = (int)c->rot_steps;

    const float *cos_tab = s->cos_tab;
    const float *sin_tab = s->sin_tab;
    float *target = (c->update == SB_UPDATE_DEFERRED) ? s->dep : s->grid;

    const sb_sense_ctx k = {
        .grid = s->grid, .cos_tab = cos_tab, .sin_tab = sin_tab,
        .fw = fw, .fh = fh, .sdist = sdist,
        .xmask = xmask, .ymask = ymask, .log2w = log2w,
    };

    for (uint32_t i = 0; i < c->agents; i++) {
        int d = (int)s->adir[i];
        float x = s->ax[i];
        float y = s->ay[i];

        const int dl = (d - ss + SB_NDIR) % SB_NDIR;
        const int dr = (d + ss) % SB_NDIR;

        const float fl = sb_sense(&k, x, y, dl);
        const float fc = sb_sense(&k, x, y, d);
        const float fr = sb_sense(&k, x, y, dr);

        if (fc >= fl && fc >= fr) {
            /* straight on */
        } else if (fc < fl && fc < fr) {
            if (xoshiro128pp(&s->arng[(size_t)i * 4]) & 1u)
                d = (d + rs) % SB_NDIR;
            else
                d = (d - rs + SB_NDIR) % SB_NDIR;
        } else if (fl > fr) {
            d = (d - rs + SB_NDIR) % SB_NDIR;
        } else {
            d = (d + rs) % SB_NDIR;
        }

        x = wrapf(x + cos_tab[d] * step, fw);
        y = wrapf(y + sin_tab[d] * step, fh);

        const uint32_t idx = (((uint32_t)y & ymask) << log2w) | ((uint32_t)x & xmask);
        target[idx] = target[idx] + deposit;

        s->adir[i] = (uint16_t)d;
        s->ax[i] = x;
        s->ay[i] = y;
    }
}

/* ---- diffusion + decay (SPEC-1 section 5.4) ----------------------------- */

static void sb_diffuse_pass(sb_sim *s) {
    const sb_config *c = &s->cfg;
    const uint32_t w = c->width, h = c->height, log2w = c->log2w;
    const uint32_t xmask = w - 1u, ymask = h - 1u;
    const float decay = c->decay;
    const float *src = s->grid;
    float *dst = s->scratch;

    for (uint32_t y = 0; y < h; y++) {
        const uint32_t ym = (y - 1u) & ymask;
        const uint32_t yp = (y + 1u) & ymask;
        const uint32_t rowm = ym << log2w;
        const uint32_t row0 = y << log2w;
        const uint32_t rowp = yp << log2w;

        for (uint32_t x = 0; x < w; x++) {
            const uint32_t xm = (x - 1u) & xmask;
            const uint32_t xp = (x + 1u) & xmask;

            /* Summation order is normative. Do not reorder, do not fuse. */
            float acc = src[rowm | xm];
            acc = acc + src[rowm | x];
            acc = acc + src[rowm | xp];
            acc = acc + src[row0 | xm];
            acc = acc + 4.0f * src[row0 | x];
            acc = acc + src[row0 | xp];
            acc = acc + src[rowp | xm];
            acc = acc + src[rowp | x];
            acc = acc + src[rowp | xp];

            dst[row0 | x] = (acc / 12.0f) * decay;
        }
    }

    s->grid = dst;
    s->scratch = (float *)src;
}

void sb_tick(sb_sim *s) {
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
    for (uint32_t i = 0; i < s->cfg.agents; i++) {
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
