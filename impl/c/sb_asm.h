/* slimebench -- hand-written assembly diffusion kernel (benchmark class V).
 *
 * The fourth point on the vectorisation axis. The other three are the scalar
 * loop the compiler autovectorises as it sees fit (sb_agent.h), the same loop
 * at -O3 -march=native, and the intrinsics kernel (sb_simd.c). This one is
 * impl/asm/sb_diffuse_avx512.S: GNU as, no compiler between the source and
 * the instruction stream.
 *
 * It exists to answer a specific question rather than to be fast on
 * principle. The intrinsics kernel reads each row three times per output
 * vector; the assembly kernel reads it once and derives the two shifted views
 * with VALIGND. That is a strategy choice a compiler will not make on its
 * own, and whether it pays is the measurement.
 *
 * Availability is width-dependent, not just CPU-dependent: see sb_asm.c.
 */
#ifndef SB_ASM_H
#define SB_ASM_H

#include "sb_core.h"

/* Non-zero if the assembly kernel can run this configuration. On 0, `why`
 * (if non-NULL) is set to a static string saying what is missing. */
int sb_asm_available(const sb_config *cfg, const char **why);

/* Name of the kernel that would run: "asm-avx512" or "none". */
const char *sb_asm_name(void);

/* SPEC-1 section 5.4 over rows [y0, y1). Bit-identical to sb_diffuse_rows().
 * Caller must have checked sb_asm_available(). */
void sb_diffuse_rows_asm(const sb_sim *s, const float *src, float *dst,
                         uint32_t y0, uint32_t y1);

#endif /* SB_ASM_H */
