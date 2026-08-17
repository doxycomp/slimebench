#include "sb_simd.h"

#include "sb_agent.h"

#if defined(__AVX512F__) || defined(__AVX2__)
#include <immintrin.h>
#define SB_HAVE_SIMD 1
#else
#define SB_HAVE_SIMD 0
#endif

#if defined(__AVX512F__)
#define SB_VW 16
typedef __m512 sb_vec;
#define SB_LOADU(p)   _mm512_loadu_ps(p)
#define SB_STOREU(p, v) _mm512_storeu_ps((p), (v))
#define SB_SET1(x)    _mm512_set1_ps(x)
#define SB_ADD(a, b)  _mm512_add_ps((a), (b))
#define SB_MUL(a, b)  _mm512_mul_ps((a), (b))
#define SB_DIV(a, b)  _mm512_div_ps((a), (b))
#define SB_NAME "avx512f"
#elif defined(__AVX2__)
#define SB_VW 8
typedef __m256 sb_vec;
#define SB_LOADU(p)   _mm256_loadu_ps(p)
#define SB_STOREU(p, v) _mm256_storeu_ps((p), (v))
#define SB_SET1(x)    _mm256_set1_ps(x)
#define SB_ADD(a, b)  _mm256_add_ps((a), (b))
#define SB_MUL(a, b)  _mm256_mul_ps((a), (b))
#define SB_DIV(a, b)  _mm256_div_ps((a), (b))
#define SB_NAME "avx2"
#else
#define SB_VW 1
#define SB_NAME "scalar"
#endif

int sb_simd_available(void) { return SB_HAVE_SIMD; }
const char *sb_simd_name(void) { return SB_NAME; }

#if SB_HAVE_SIMD

/* One output cell, scalar. Used for the two wrapping columns, which the
 * vector body cannot reach with plain unaligned loads. */
static inline void diffuse_cell(const float *src, float *dst, uint32_t x,
                                uint32_t rowm, uint32_t row0, uint32_t rowp,
                                uint32_t xmask, float decay) {
    const uint32_t xm = (x - 1u) & xmask;
    const uint32_t xp = (x + 1u) & xmask;

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

void sb_diffuse_rows_simd(const sb_sim *s, const float *src, float *dst,
                          uint32_t y0, uint32_t y1) {
    const uint32_t w = s->cfg.width;
    const uint32_t log2w = s->cfg.log2w;
    const uint32_t xmask = w - 1u;
    const uint32_t ymask = s->cfg.height - 1u;
    const float decay = s->cfg.decay;

    /* Narrow grids would leave no vector body worth entering. */
    if (w < (uint32_t)(2 * SB_VW)) {
        sb_diffuse_rows(s, src, dst, y0, y1);
        return;
    }

    const sb_vec vfour = SB_SET1(4.0f);
    const sb_vec vtwelve = SB_SET1(12.0f);
    const sb_vec vdecay = SB_SET1(decay);

    for (uint32_t y = y0; y < y1; y++) {
        const uint32_t rowm = ((y - 1u) & ymask) << log2w;
        const uint32_t row0 = y << log2w;
        const uint32_t rowp = ((y + 1u) & ymask) << log2w;

        const float *pm = src + rowm;
        const float *p0 = src + row0;
        const float *pp = src + rowp;
        float *out = dst + row0;

        /* Column 0 wraps to w-1 on the left. */
        diffuse_cell(src, dst, 0, rowm, row0, rowp, xmask, decay);

        /* Vector body over the interior, where x-1 and x+1 are in range.
         * Same nine terms, same order, one output cell per lane. */
        uint32_t x = 1;
        for (; x + SB_VW <= w - 1u; x += SB_VW) {
            sb_vec acc = SB_LOADU(pm + x - 1);
            acc = SB_ADD(acc, SB_LOADU(pm + x));
            acc = SB_ADD(acc, SB_LOADU(pm + x + 1));
            acc = SB_ADD(acc, SB_LOADU(p0 + x - 1));
            acc = SB_ADD(acc, SB_MUL(vfour, SB_LOADU(p0 + x)));
            acc = SB_ADD(acc, SB_LOADU(p0 + x + 1));
            acc = SB_ADD(acc, SB_LOADU(pp + x - 1));
            acc = SB_ADD(acc, SB_LOADU(pp + x));
            acc = SB_ADD(acc, SB_LOADU(pp + x + 1));
            SB_STOREU(out + x, SB_MUL(SB_DIV(acc, vtwelve), vdecay));
        }

        /* Remainder plus the wrapping last column. */
        for (; x < w; x++)
            diffuse_cell(src, dst, x, rowm, row0, rowp, xmask, decay);
    }
}

#else  /* no vector ISA compiled in */

void sb_diffuse_rows_simd(const sb_sim *s, const float *src, float *dst,
                          uint32_t y0, uint32_t y1) {
    sb_diffuse_rows(s, src, dst, y0, y1);
}

#endif
