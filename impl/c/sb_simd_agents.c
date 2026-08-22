/* slimebench -- the agent pass, vectorised (SPEC-1 section 5.3).
 *
 * ## Why this file exists
 *
 * Everything vectorised in this project so far -- class V in five languages,
 * the hand-written AVX-512 stencil, Java's Vector API, C#'s Vector512 --
 * attacks the diffusion pass. Measured on the reference C build, the
 * diffusion pass is 11 % of a tick at `medium` and 22 % at `small`. The agent
 * pass is the other 78 to 89 %, and no port vectorises it.
 *
 * sb_simd.h said as much and called measuring it future work: three sensor
 * reads are a gather with data-dependent addresses, and gathers on Zen are
 * "barely faster than scalar loads". That is a plausible claim and it was
 * never measured. This file measures it.
 *
 * ## Why it can be bit-exact
 *
 * In `deferred` mode the pass reads `grid` and writes `dep`, two different
 * arrays, so no agent can observe another's deposit and the agents are
 * genuinely independent. (In `serial` mode they are not, which is why SPEC-1
 * 5.5 forbids parallelising it, and why this path refuses that mode.)
 *
 * Three things would break exactness and are avoided:
 *
 *   - FMA. `x + cos*dist` fused is a different float. Every multiply and add
 *     here is a separate intrinsic, and the build passes -ffp-contract=off.
 *   - Cross-lane work. There is none: lane i computes exactly what the scalar
 *     loop computes for agent i.
 *   - Drawing from the PRNG on lanes that should not draw. Only the dead-end
 *     branch draws -- 1.3 % of agents -- and a lane that draws speculatively
 *     would advance a stream that must not advance. So the PRNG is not
 *     vectorised at all: the dead-end lanes are handled scalar, in ascending
 *     lane order, over the bits of the mask. At 1.3 % that costs nothing, and
 *     it makes the exactness argument a matter of reading the code rather
 *     than of trusting a masked-store argument.
 *
 * The deposit stays scalar too. Several agents in one vector routinely target
 * the same cell, so a scatter needs conflict detection; and the deposit is
 * one add against eleven gathers, so vectorising it is not where the time is.
 */
#include "sb_simd.h"

#include "sb_agent.h"

/* AVX512BW as well as F: widening sixteen uint16 directions into lanes is
 * VPMOVZXWD with a zmm destination, which is a BW instruction. Every part
 * that has AVX-512 at all has both, but the guard should say what the code
 * actually needs rather than what is usually true. */
#if defined(__AVX512F__) && defined(__AVX512BW__)
#include <immintrin.h>
#define SB_AGENTS_VEC 1
#else
#define SB_AGENTS_VEC 0
#endif

int sb_simd_agents_available(void) { return SB_AGENTS_VEC; }

#if SB_AGENTS_VEC

#define VW 16

/* SPEC-1 2.2, sixteen at a time: if (v < 0) v += m; if (v >= m) v -= m. */
static inline __m512 wrapv(__m512 v, __m512 m) {
    const __m512 zero = _mm512_setzero_ps();
    const __mmask16 lo = _mm512_cmp_ps_mask(v, zero, _CMP_LT_OQ);
    v = _mm512_mask_add_ps(v, lo, v, m);
    const __mmask16 hi = _mm512_cmp_ps_mask(v, m, _CMP_GE_OQ);
    return _mm512_mask_sub_ps(v, hi, v, m);
}

/* (d + delta) mod NDIR for d in [0, NDIR) and delta in (-NDIR, NDIR), done as
 * the single conditional subtract the range allows -- not a division. */
static inline __m512i modv(__m512i t, __m512i ndir) {
    const __mmask16 ge = _mm512_cmpge_epi32_mask(t, ndir);
    return _mm512_mask_sub_epi32(t, ge, t, ndir);
}

/* The cell a sensor at direction `d` reads, sixteen agents at a time. */
static inline __m512 sensev(const sb_agent_ctx *k, __m512 x, __m512 y,
                            __m512i d, __m512 fw, __m512 fh, __m512 sdist,
                            __m512i xmask, __m512i ymask, __m512i log2w) {
    const __m512 c = _mm512_i32gather_ps(d, k->cos_tab, 4);
    const __m512 s = _mm512_i32gather_ps(d, k->sin_tab, 4);
    /* Separate multiply and add. Fusing these is the one thing that would
     * take this out of tier A. */
    const __m512 sx = wrapv(_mm512_add_ps(x, _mm512_mul_ps(c, sdist)), fw);
    const __m512 sy = wrapv(_mm512_add_ps(y, _mm512_mul_ps(s, sdist)), fh);
    const __m512i ix = _mm512_and_epi32(_mm512_cvttps_epu32(sx), xmask);
    const __m512i iy = _mm512_and_epi32(_mm512_cvttps_epu32(sy), ymask);
    const __m512i idx = _mm512_or_epi32(_mm512_sllv_epi32(iy, log2w), ix);
    return _mm512_i32gather_ps(idx, k->grid, 4);
}

/* Advances agents [i0, i0+VW) and writes their target cells into out[0..VW).
 * Bit-identical to sixteen calls to sb_agent_step. */
static inline void agents_block(const sb_agent_ctx *k, sb_sim *s, uint32_t i0,
                                uint32_t *out) {
    const __m512 fw = _mm512_set1_ps(k->fw);
    const __m512 fh = _mm512_set1_ps(k->fh);
    const __m512 sdist = _mm512_set1_ps(k->sdist);
    const __m512 step = _mm512_set1_ps(k->step);
    const __m512i xmask = _mm512_set1_epi32((int)k->xmask);
    const __m512i ymask = _mm512_set1_epi32((int)k->ymask);
    const __m512i log2w = _mm512_set1_epi32((int)k->log2w);
    const __m512i ndir = _mm512_set1_epi32(SB_NDIR);
    const __m512i ss = _mm512_set1_epi32(k->ss);
    const __m512i rs = _mm512_set1_epi32(k->rs);

    /* adir is uint16_t; widen sixteen of them to lanes. */
    const __m512i d = _mm512_cvtepu16_epi32(
        _mm256_loadu_si256((const __m256i *)(const void *)(s->adir + i0)));
    __m512 x = _mm512_loadu_ps(s->ax + i0);
    __m512 y = _mm512_loadu_ps(s->ay + i0);

    const __m512i dl = modv(_mm512_sub_epi32(_mm512_add_epi32(d, ndir), ss),
                            ndir);
    const __m512i dr = modv(_mm512_add_epi32(d, ss), ndir);

    const __m512 fl = sensev(k, x, y, dl, fw, fh, sdist, xmask, ymask, log2w);
    const __m512 fc = sensev(k, x, y, d, fw, fh, sdist, xmask, ymask, log2w);
    const __m512 fr = sensev(k, x, y, dr, fw, fh, sdist, xmask, ymask, log2w);

    /* The same four cases as sb_agent_step, in the same order of precedence,
     * as masks rather than as branches. */
    const __mmask16 straight =
        _mm512_cmp_ps_mask(fc, fl, _CMP_GE_OQ) &
        _mm512_cmp_ps_mask(fc, fr, _CMP_GE_OQ);
    const __mmask16 dead =
        (__mmask16)(~straight) &
        _mm512_cmp_ps_mask(fc, fl, _CMP_LT_OQ) &
        _mm512_cmp_ps_mask(fc, fr, _CMP_LT_OQ);
    const __mmask16 rest = (__mmask16)(~(straight | dead));
    const __mmask16 left = rest & _mm512_cmp_ps_mask(fl, fr, _CMP_GT_OQ);
    const __mmask16 right = (__mmask16)(rest & ~left);

    const __m512i dplus = modv(_mm512_add_epi32(d, rs), ndir);
    const __m512i dminus = modv(_mm512_sub_epi32(_mm512_add_epi32(d, ndir), rs),
                                ndir);

    __m512i dn = d;
    dn = _mm512_mask_mov_epi32(dn, left, dminus);
    dn = _mm512_mask_mov_epi32(dn, right, dplus);

    /* The dead-end lanes, scalar and in ascending order, because each one
     * advances its own PRNG stream and only lanes that take this branch may
     * advance. */
    if (dead) {
        uint32_t dp[VW], dm[VW], dv[VW];
        _mm512_storeu_si512((void *)dp, dplus);
        _mm512_storeu_si512((void *)dm, dminus);
        _mm512_storeu_si512((void *)dv, dn);
        __mmask16 m = dead;
        while (m) {
            const int lane = __builtin_ctz((unsigned)m);
            m = (__mmask16)(m & (m - 1u));
            dv[lane] = (sb_xoshiro128pp(&s->arng[((size_t)i0 + lane) * 4]) & 1u)
                       ? dp[lane] : dm[lane];
        }
        dn = _mm512_loadu_si512((const void *)dv);
    }

    const __m512 cn = _mm512_i32gather_ps(dn, k->cos_tab, 4);
    const __m512 sn = _mm512_i32gather_ps(dn, k->sin_tab, 4);
    x = wrapv(_mm512_add_ps(x, _mm512_mul_ps(cn, step)), fw);
    y = wrapv(_mm512_add_ps(y, _mm512_mul_ps(sn, step)), fh);

    _mm256_storeu_si256((__m256i *)(void *)(s->adir + i0),
                        _mm512_cvtepi32_epi16(dn));
    _mm512_storeu_ps(s->ax + i0, x);
    _mm512_storeu_ps(s->ay + i0, y);

    const __m512i ix = _mm512_and_epi32(_mm512_cvttps_epu32(x), xmask);
    const __m512i iy = _mm512_and_epi32(_mm512_cvttps_epu32(y), ymask);
    _mm512_storeu_si512((void *)out,
                        _mm512_or_epi32(_mm512_sllv_epi32(iy, log2w), ix));
}

void sb_simd_agents(sb_sim *s, uint32_t i0, uint32_t i1, uint32_t *out) {
    const sb_agent_ctx k = sb_agent_ctx_make(s);
    uint32_t i = i0;
    for (; i + VW <= i1; i += VW)
        agents_block(&k, s, i, out + (i - i0));
    for (; i < i1; i++)
        out[i - i0] = sb_agent_step(&k, s, i);
}

#else

void sb_simd_agents(sb_sim *s, uint32_t i0, uint32_t i1, uint32_t *out) {
    const sb_agent_ctx k = sb_agent_ctx_make(s);
    for (uint32_t i = i0; i < i1; i++)
        out[i - i0] = sb_agent_step(&k, s, i);
}

#endif /* SB_AGENTS_VEC */
