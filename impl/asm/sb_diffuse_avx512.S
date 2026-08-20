/* slimebench -- the SPEC-1 section 5.4 stencil, hand-written AVX-512.
 *
 * GNU as, System V AMD64 ABI, x86-64 with AVX-512F.
 *
 * ## Why write this by hand at all
 *
 * sb_simd.c already vectorises this kernel with intrinsics and is bit-exact.
 * Writing the same thing again in assembly to prove the assembler works would
 * measure nothing. So this file does not transliterate the intrinsics -- it
 * uses a different memory strategy, one the compiler will not choose:
 *
 *   The intrinsics kernel issues nine unaligned loads per output vector: for
 *   each of the three rows it loads at x-1, x and x+1. Those three loads read
 *   almost the same bytes, and two of the three cross a cache line whenever
 *   the row is 64-byte aligned.
 *
 *   This kernel issues three. It keeps the previous, current and next 16-lane
 *   vector of each row live in registers and manufactures the x-1 and x+1
 *   views with VALIGND, which concatenates two vectors and shifts the result
 *   by a whole number of dwords across all 512 bits. Per output vector: three
 *   loads, six VALIGND, one store.
 *
 * VALIGND is the reason this is AVX-512 only. AVX2's VPALIGNR shifts inside
 * each 128-bit half and cannot move a lane across the middle, so on AVX2 the
 * same idea costs a VPERM2F128 per shift and stops being a win. An AVX2
 * version of this file would therefore be the intrinsics kernel written out
 * longhand, which is the thing worth not doing.
 *
 * ## The second thing hand-written buys
 *
 * The wrap. The grid is a torus and the row is a power of two long, so the
 * byte offset of the next vector is (xo + 64) & (rowbytes - 1) -- one AND.
 * That makes the first and last vector of a row ordinary iterations: the
 * "previous" vector of x=0 is simply the last vector of the row, and VALIGND
 * pulls its top lane into lane 0. The intrinsics kernel cannot express that
 * and peels a scalar head and tail off every row.
 *
 * ## Conformance
 *
 * Tier A, bit-identical to sb_diffuse_rows(). SPEC-1 section 5.4 fixes the
 * order of the nine additions and this kernel performs them in that order,
 * per lane, with no cross-lane arithmetic: lane i computes exactly what the
 * scalar loop computes for cell i. The multiply by 4 is a separate VMULPS
 * (never VFMADD -- fusing changes the rounding) and the division by 12 is a
 * real VDIVPS, not a multiply by an approximate reciprocal.
 *
 * ## Constraint
 *
 * The loop is unrolled four times over a four-slot register ring, so the ring
 * returns to its starting rotation each round and no register-to-register
 * moves are needed to advance it. That requires the row to be a whole number
 * of rounds: width must be a multiple of 64. Every preset is. sb_asm.c checks
 * and refuses rather than computing something else.
 */

    .text
    .globl  sb_diffuse_rows_asm_avx512
    .type   sb_diffuse_rows_asm_avx512, @function

/* One 16-lane output vector.
 *
 *   \am \bm \cm   ring slots (prev, cur, next) for the row above   -> zmm0..3
 *   \a0 \b0 \c0   ring slots for the row itself                    -> zmm4..7
 *   \ap \bp \cp   ring slots for the row below                     -> zmm8..11
 *   \off          byte offset of this vector within the round
 *
 * zmm12/13 hold the shifted views, zmm14 the accumulator, zmm15 the 4x term.
 * zmm16 = 4.0, zmm17 = 12.0, zmm18 = decay, all broadcast.
 */
    .macro STENCIL am, bm, cm, a0, b0, c0, ap, bp, cp, off
    /* Offset of the vector one step to the right, wrapped around the row. */
    leaq    \off+64(%r15), %r11
    andq    %rbp, %r11
    vmovups (%rbx,%r11), %zmm\cm
    vmovups (%r12,%r11), %zmm\c0
    vmovups (%r13,%r11), %zmm\cp

    /* Row above: [prev[15], cur[0..14]] and [cur[1..15], next[0]]. */
    valignd $15, %zmm\am, %zmm\bm, %zmm12
    valignd $1,  %zmm\bm, %zmm\cm, %zmm13
    vaddps  %zmm\bm, %zmm12, %zmm14         /* acc  = up_left + up      */
    vaddps  %zmm13, %zmm14, %zmm14          /* acc += up_right          */

    /* Own row. The 4x is a separate multiply: SPEC-1 1.2 forbids the fuse. */
    valignd $15, %zmm\a0, %zmm\b0, %zmm12
    valignd $1,  %zmm\b0, %zmm\c0, %zmm13
    vaddps  %zmm12, %zmm14, %zmm14          /* acc += left              */
    vmulps  %zmm16, %zmm\b0, %zmm15         /* t    = 4.0 * centre      */
    vaddps  %zmm15, %zmm14, %zmm14          /* acc += t                 */
    vaddps  %zmm13, %zmm14, %zmm14          /* acc += right             */

    /* Row below. */
    valignd $15, %zmm\ap, %zmm\bp, %zmm12
    valignd $1,  %zmm\bp, %zmm\cp, %zmm13
    vaddps  %zmm12, %zmm14, %zmm14
    vaddps  %zmm\bp, %zmm14, %zmm14
    vaddps  %zmm13, %zmm14, %zmm14

    vdivps  %zmm17, %zmm14, %zmm14          /* real division by 12      */
    vmulps  %zmm18, %zmm14, %zmm14
    vmovups %zmm14, \off(%r14,%r15)
    .endm

/* void sb_diffuse_rows_asm_avx512(const float *src, float *dst,
 *                                 uint32_t w, uint32_t log2w, uint32_t ymask,
 *                                 uint32_t y0, uint32_t y1, float decay);
 *
 * SysV AMD64: rdi src, rsi dst, edx w, ecx log2w, r8d ymask, r9d y0,
 * 8(%rsp) y1, xmm0 decay. Six integer registers is exactly what the ABI
 * passes, so y1 is the one argument that arrives on the stack -- read it
 * before anything is pushed.
 */
sb_diffuse_rows_asm_avx512:
    endbr64
    movl    8(%rsp), %eax               /* y1 */
    cmpl    %eax, %r9d
    jae     .Ldone_early                /* empty range: nothing to do */

    pushq   %rbx
    pushq   %rbp
    pushq   %r12
    pushq   %r13
    pushq   %r14
    pushq   %r15
    movl    %eax, %r10d                 /* r10d = y1 */

    /* rowbytes is a power of two because width is, so mask = rowbytes-1 is
     * all the wrap arithmetic this kernel needs. */
    movl    %edx, %ebp
    shll    $2, %ebp
    decl    %ebp                        /* rbp = rowbytes - 1 */

    vbroadcastss %xmm0, %zmm18          /* decay */
    movl    $0x40800000, %eax           /* 4.0f  */
    vpbroadcastd %eax, %zmm16
    movl    $0x41400000, %eax           /* 12.0f */
    vpbroadcastd %eax, %zmm17

    addl    $2, %ecx                    /* shift from row index to bytes */

.Lrow:
    /* pm = src + (((y-1) & ymask) << (log2w+2)) */
    leal    -1(%r9), %eax
    andl    %r8d, %eax
    shll    %cl, %eax
    leaq    (%rdi,%rax), %rbx

    /* p0 = src + (y << (log2w+2)); pd = dst + same */
    movl    %r9d, %eax
    shll    %cl, %eax
    leaq    (%rdi,%rax), %r12
    leaq    (%rsi,%rax), %r14

    /* pp = src + (((y+1) & ymask) << (log2w+2)) */
    leal    1(%r9), %eax
    andl    %r8d, %eax
    shll    %cl, %eax
    leaq    (%rdi,%rax), %r13

    /* Prime the ring. Slot 0 is the vector to the left of x=0, which on a
     * torus is the last vector of the row; slot 1 is x=0 itself. */
    movq    %rbp, %r11
    subq    $63, %r11                   /* (rowbytes-1) - 63 = rowbytes-64 */
    vmovups (%rbx,%r11), %zmm0
    vmovups (%r12,%r11), %zmm4
    vmovups (%r13,%r11), %zmm8
    vmovups (%rbx), %zmm1
    vmovups (%r12), %zmm5
    vmovups (%r13), %zmm9

    xorl    %r15d, %r15d                /* xo = 0 */

.Lround:
    STENCIL 0,1,2,  4,5,6,  8,9,10,  0
    STENCIL 1,2,3,  5,6,7,  9,10,11, 64
    STENCIL 2,3,0,  6,7,4,  10,11,8, 128
    STENCIL 3,0,1,  7,4,5,  11,8,9,  192
    /* Four vectors advanced the ring by four slots, so it is back where it
     * started: slot 0 is again the vector left of the new xo. No moves. */
    addq    $256, %r15
    cmpq    %rbp, %r15
    jbe     .Lround

    incl    %r9d
    cmpl    %r10d, %r9d
    jb      .Lrow

    vzeroupper
    popq    %r15
    popq    %r14
    popq    %r13
    popq    %r12
    popq    %rbp
    popq    %rbx
.Ldone_early:
    ret

    .size   sb_diffuse_rows_asm_avx512, .-sb_diffuse_rows_asm_avx512
    .section .note.GNU-stack,"",@progbits
