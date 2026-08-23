/* slimebench -- explicitly vectorised diffusion pass (benchmark class V).
 *
 * ## Why this is still conformance tier A
 *
 * SPEC-1 section 5.4 fixes the order of the nine additions. A cross-lane
 * reduction would reorder them and land in tier C -- but this kernel does no
 * cross-lane work at all. Each lane computes one output cell, running the
 * identical operation sequence in the identical order on its own data. Lane i
 * of the vector produces exactly what the scalar loop produces for cell i.
 *
 * The one thing that would break it is FMA: `4.0f * c + acc` fused into a
 * single rounding is a different number. So the multiply and the add stay
 * separate intrinsics, and the division by 12 is a real _mm*_div_ps rather
 * than a multiply by the reciprocal.
 *
 * That makes this the rare case where SIMD is free of numeric caveats -- the
 * BUILDPLAN originally assumed the opposite.
 *
 * ## What is NOT vectorised, and why
 *
 * The deposit. Several agents in one vector routinely target the same cell,
 * so a scatter needs AVX-512 conflict detection and a serialising fallback.
 * It stays scalar, which also makes the exactness argument trivial.
 *
 * The agent *step* used to be in this list, on the argument that its three
 * sensor reads are a gather with data-dependent addresses and that gathers on
 * Zen are barely faster than scalar loads. That was plausible and unmeasured.
 * sb_simd_agents.c measures it; docs/RESULTS.md says what came out.
 */
#ifndef SB_SIMD_H
#define SB_SIMD_H

#include "sb_core.h"

/* 0 if this build has no vector path for the agent pass. See
 * sb_simd_agents.c for why that is a separate question from the stencil. */
int sb_simd_agents_available(void);

/* SPEC-1 section 5.3 for agents [i0, i1), vectorised. Writes each agent's
 * target cell into out[i - i0]; the caller applies the deposits, in that
 * order, which is what keeps this bit-identical to the scalar loop.
 *
 * `deferred` only: in `serial` mode an agent sees its predecessors' deposits
 * and the pass is not independent (SPEC-1 5.5). */
void sb_simd_agents(sb_sim *s, uint32_t i0, uint32_t i1, uint32_t *out);

/* 0 if this build has no vector path (kernel falls back to scalar). */
int sb_simd_available(void);
/* Name of the widest ISA compiled in: "avx512f", "avx2", or "scalar". */
const char *sb_simd_name(void);

/* SPEC-1 section 5.4 over rows [y0, y1), vectorised. Bit-identical to
 * sb_diffuse_rows(). */
void sb_diffuse_rows_simd(const sb_sim *s, const float *src, float *dst,
                          uint32_t y0, uint32_t y1);

#endif /* SB_SIMD_H */
