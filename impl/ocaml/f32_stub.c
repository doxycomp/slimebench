/* One SSE instruction, wrapped in the cheapest call OCaml can make.
 *
 * OCaml 4.14 has no float32 type, so the only rounding available in the
 * language is Int32.float_of_bits (Int32.bits_of_float x). Both halves of that
 * are already declared [@@unboxed] [@@noalloc] in the standard library, so the
 * cost is not boxing -- it is that there are *two* runtime calls where the
 * hardware needs one cvtsd2ss and one cvtss2sd.
 *
 * Measured on a dependency chain, which is where the stencil puts it:
 *   no rounding          2.25 ns/op
 *   Int32 round-trip     7.03 ns/op
 *   this stub            5.04 ns/op
 *
 * Declaring it [@@unboxed] [@@noalloc] is what makes it cheap: the argument
 * and result stay in XMM registers and the compiler emits no GC poll around
 * the call. The bytecode entry point below is required by the FFI and never
 * runs in a native build.
 */
#include <caml/mlvalues.h>
#include <caml/alloc.h>

double sb_f32(double x) { return (double)(float)x; }

value sb_f32_byte(value v) { return caml_copy_double((double)(float)Double_val(v)); }
