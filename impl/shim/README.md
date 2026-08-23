# shim — the five raylib calls that need a C wrapper

raylib takes `Image`, `Texture2D` and `Color` **by value**, and two of the
bindings in this repository cannot express that: Haskell's `foreign import
ccall` marshals scalars and pointers only, and Perl's `FFI::Platypus` passes
records by pointer. So the five calls that need it get a one-line wrapper here
and those two frontends bind these instead. Everything else they use —
`InitWindow`, `BeginDrawing` and the rest — takes scalars and is bound
directly.

Two more functions return `sizeof(Image)` and `sizeof(Texture2D)`, so the
Haskell `Storable` instances are checked against the header rather than guessed
from it.

It is a separate directory rather than a copy in each port because both
frontends must link **the same** shim against **the same**
`/usr/local/lib/libraylib.so` that the C, Rust and Python frontends use.
`h-raylib` and the various Perl raylib distributions vendor and rebuild raylib;
comparing a language against a *different build* of the library would measure
the wrong thing, and that is what class R exists not to do.

## Targets

<!-- sb:impl targets -->
_No benchmark target builds from this directory._
<!-- /sb:impl -->

## Files

<!-- sb:impl files -->
| File | Lines | What |
|---|---:|---|
| `build.sh` | 18 | Build the raylib by-value shim as a shared object, for the Perl frontend |
| `raylib_shim.c` | 53 | By-value shims for the raylib frontends that cannot pass structs by value |
<!-- /sb:impl -->

## Building

```bash
bash impl/shim/build.sh
```

Class R is [docs/RESULTS.md](../../docs/RESULTS.md) §10.
