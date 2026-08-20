/* Dispatcher for the hand-written kernel in impl/asm/.
 *
 * Everything that is plumbing rather than kernel lives here, in C: the CPU
 * feature test, the width check, and the unpacking of sb_sim into the flat
 * argument list the assembly expects. Putting the CPUID in assembly too would
 * add lines without adding information.
 */
#include "sb_asm.h"

/* Built only when the build actually links the impl/asm sources -- see the
 * Makefile ASM=1 knob. Without it the whole file collapses to "not available", so a
 * build on aarch64 or with a toolchain that cannot assemble AVX-512 still
 * compiles and honestly reports that the kernel is missing. */
#if defined(SB_HAVE_ASM) && (defined(__x86_64__) || defined(_M_X64))
#define SB_ASM_BUILT 1

void sb_diffuse_rows_asm_avx512(const float *src, float *dst,
                                uint32_t w, uint32_t log2w, uint32_t ymask,
                                uint32_t y0, uint32_t y1, float decay);
#else
#define SB_ASM_BUILT 0
#endif

/* The four-slot register ring in the kernel is unrolled four times over
 * sixteen lanes, so a row is a whole number of rounds only at this multiple.
 * Every SPEC-1 preset satisfies it; a hand-rolled --width 32 does not, and
 * gets an error rather than a wrong grid. */
#define SB_ASM_WIDTH_MULTIPLE 64u

int sb_asm_available(const sb_config *cfg, const char **why) {
#if !SB_ASM_BUILT
    if (why) *why = "not built with ASM=1 (or not x86-64)";
    return 0;
#else
    if (!__builtin_cpu_supports("avx512f")) {
        if (why) *why = "CPU has no AVX-512F";
        return 0;
    }
    if (cfg->width % SB_ASM_WIDTH_MULTIPLE != 0u) {
        if (why) *why = "width is not a multiple of 64";
        return 0;
    }
    if (why) *why = NULL;
    return 1;
#endif
}

const char *sb_asm_name(void) {
#if SB_ASM_BUILT
    return __builtin_cpu_supports("avx512f") ? "asm-avx512" : "none";
#else
    return "none";
#endif
}

void sb_diffuse_rows_asm(const sb_sim *s, const float *src, float *dst,
                         uint32_t y0, uint32_t y1) {
#if SB_ASM_BUILT
    sb_diffuse_rows_asm_avx512(src, dst, s->cfg.width, s->cfg.log2w,
                               s->cfg.height - 1u, y0, y1, s->cfg.decay);
#else
    (void)s; (void)src; (void)dst; (void)y0; (void)y1;
#endif
}
