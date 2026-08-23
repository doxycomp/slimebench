# asm — hand-written AVX-512, and the reason it exists

The intrinsics kernel in [`impl/c`](../c/) is already conformance tier A and
already more than twice the scalar loop. Writing the same thing again in
assembly would measure the assembler. So this file does something the
intrinsics cannot express instead — same arithmetic, different memory
strategy:

> The intrinsics kernel issues **nine unaligned loads per output vector**:
> three rows times `x-1`, `x`, `x+1`. Those three read almost the same bytes.
>
> This one issues **three**. It keeps the previous, current and next 16-lane
> vector of each row in registers and manufactures the shifted views with
> `VALIGND`, which concatenates two vectors and shifts by whole doublewords
> across all 512 bits. Per output vector: three loads, six `VALIGND`, one
> store.

Two side effects that are not in the timing table:

- **The torus wrap becomes free.** The row is a power of two long, so the byte
  offset of the next vector is `(xo + 64) & (rowbytes - 1)` — a single `AND`.
  That makes the first and last vector of a row ordinary iterations, where the
  intrinsics kernel peels a scalar head and tail off every row.
- **`VALIGND` is why this stays AVX-512.** AVX2's `VPALIGNR` shifts inside the
  two 128-bit halves and cannot move a lane across the middle; the same idea
  costs a `VPERM2F128` per shift and stops paying. An AVX2 version of this file
  would be the intrinsics kernel written out longhand.

The agent pass has no equivalent file, and the header of this one explains why:
two strategies a compiler will not choose were tried and measured, and the one
that paid — an interleaved, pre-scaled trig table — is expressible in
intrinsics, so it lives there. Writing a transliteration to report 0 % is the
thing this file argues against.

## Targets

<!-- sb:impl targets -->
_No benchmark target builds from this directory._
<!-- /sb:impl -->

## Files

<!-- sb:impl files -->
| File | Lines | What |
|---|---:|---|
| `sb_diffuse_avx512.S` | 199 | The SPEC-1 section 5.4 stencil, hand-written AVX-512 |
<!-- /sb:impl -->

## Reading order

One file, GNU as, System V AMD64 ABI. `impl/c/sb_asm.c` is the dispatcher and
refuses with a reason when the CPU has no AVX-512F or the width is not a
multiple of 64 — the register ring is unrolled four times over sixteen lanes.

## Building

```bash
make -C impl/c CC=clang PROFILE=o3-native ASM=1 headless
```

Selected at runtime with `--asm`. The comparison against the intrinsics is
[docs/RESULTS.md](../../docs/RESULTS.md) §8.
