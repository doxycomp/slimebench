/* The per-agent step of SPEC-1 section 5.3, shared by the serial and the
 * multi-threaded tick.
 *
 * It deliberately does NOT deposit: the three callers put the deposit in
 * three different places (the grid itself, a thread-private buffer, or an
 * index array for later binning). Returning the target cell instead keeps one
 * copy of the actual simulation rule, which is the only way the parallel path
 * can be trusted to compute the same thing.
 */
#ifndef SB_AGENT_H
#define SB_AGENT_H

#include <stdint.h>

#include "sb_core.h"

/* Grid geometry hoisted out of the hot loop; passed by value so the compiler
 * keeps it all in registers. */
typedef struct {
    const float *grid;
    const float *cos_tab;
    const float *sin_tab;
    float fw, fh, sdist, step;
    uint32_t xmask, ymask, log2w;
    int ss, rs;
} sb_agent_ctx;

static inline sb_agent_ctx sb_agent_ctx_make(const sb_sim *s) {
    sb_agent_ctx k;
    k.grid = s->grid;
    k.cos_tab = s->cos_tab;
    k.sin_tab = s->sin_tab;
    k.fw = (float)s->cfg.width;
    k.fh = (float)s->cfg.height;
    k.sdist = s->cfg.sensor_dist;
    k.step = s->cfg.step;
    k.xmask = s->cfg.width - 1u;
    k.ymask = s->cfg.height - 1u;
    k.log2w = s->cfg.log2w;
    k.ss = (int)s->cfg.sensor_steps;
    k.rs = (int)s->cfg.rot_steps;
    return k;
}

/* SPEC-1 section 2.2. */
static inline float sb_wrapf(float v, float m) {
    if (v < 0.0f) v = v + m;
    if (v >= m) v = v - m;
    return v;
}

static inline float sb_sense(const sb_agent_ctx *k, float x, float y, int d) {
    const float sx = sb_wrapf(x + k->cos_tab[d] * k->sdist, k->fw);
    const float sy = sb_wrapf(y + k->sin_tab[d] * k->sdist, k->fh);
    return k->grid[(((uint32_t)sy & k->ymask) << k->log2w) |
                   ((uint32_t)sx & k->xmask)];
}

/* Advances agent `i` and returns the cell its deposit belongs in. */
static inline uint32_t sb_agent_step(const sb_agent_ctx *k, sb_sim *s,
                                     uint32_t i) {
    int d = (int)s->adir[i];
    float x = s->ax[i];
    float y = s->ay[i];

    const int dl = (d - k->ss + SB_NDIR) % SB_NDIR;
    const int dr = (d + k->ss) % SB_NDIR;

    const float fl = sb_sense(k, x, y, dl);
    const float fc = sb_sense(k, x, y, d);
    const float fr = sb_sense(k, x, y, dr);

    if (fc >= fl && fc >= fr) {
        /* straight on */
    } else if (fc < fl && fc < fr) {
        if (sb_xoshiro128pp(&s->arng[(size_t)i * 4]) & 1u)
            d = (d + k->rs) % SB_NDIR;
        else
            d = (d - k->rs + SB_NDIR) % SB_NDIR;
    } else if (fl > fr) {
        d = (d - k->rs + SB_NDIR) % SB_NDIR;
    } else {
        d = (d + k->rs) % SB_NDIR;
    }

    x = sb_wrapf(x + k->cos_tab[d] * k->step, k->fw);
    y = sb_wrapf(y + k->sin_tab[d] * k->step, k->fh);

    s->adir[i] = (uint16_t)d;
    s->ax[i] = x;
    s->ay[i] = y;

    return (((uint32_t)y & k->ymask) << k->log2w) | ((uint32_t)x & k->xmask);
}

/* SPEC-1 section 5.4 for the row range [y0, y1). Every output cell depends
 * only on `src`, so splitting the range across threads is bit-identical to
 * running it in one go -- unconditionally, for any thread count. */
static inline void sb_diffuse_rows(const sb_sim *s, const float *src, float *dst,
                                   uint32_t y0, uint32_t y1) {
    const uint32_t w = s->cfg.width;
    const uint32_t log2w = s->cfg.log2w;
    const uint32_t xmask = w - 1u;
    const uint32_t ymask = s->cfg.height - 1u;
    const float decay = s->cfg.decay;

    for (uint32_t y = y0; y < y1; y++) {
        const uint32_t rowm = ((y - 1u) & ymask) << log2w;
        const uint32_t row0 = y << log2w;
        const uint32_t rowp = ((y + 1u) & ymask) << log2w;

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
}

#endif /* SB_AGENT_H */
