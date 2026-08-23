# pygl — the same shaders, driven from Python

This target exists to test one claim the results had been making without
evidence: **that class G measures the GPU and not the host language.**

The C host in [`impl/glcompute`](../glcompute/) allocates buffers, sets uniforms
and issues three dispatches per tick; everything that costs time happens on the
device. If that is true, a Python host running the *same shaders* on the *same
driver* should land on the same numbers.

"The same shaders" is not asserted here, it is checked. The GLSL lives in
`impl/glcompute/shaders/`, the C header is generated from it, and both hosts
report an FNV-32 of the source they actually compiled. If the two `shader_hash`
values differ, the comparison is void and the harness can see it.

Everything above the shaders is independent: this host does its own SPEC-1 §3.3
initialisation in numpy, builds its own buffers, and writes its own
uniform-setting code — about 200 lines against the C host's 480.

The result is stronger than "both produce the correct answer": the two hosts
agree on **every** grid hash including the ones that deviate from the CPU
reference, so the Python host reproduces the driver's ULP deviation exactly.

## Targets

<!-- sb:impl targets -->
| Target | Class | Backend | Compilers | Profiles |
|---|:-:|---|---|---|
| `pygl` | G | gl43 | python3 | `default` |
<!-- /sb:impl -->

## Files

<!-- sb:impl files -->
| File | Lines | What |
|---|---:|---|
| `slimebench_pygl.py` | 334 | Benchmark class G from a second language (SPEC-1 section 8.2) |
<!-- /sb:impl -->

## Reading order

One file. The header states the argument; the rest is buffer setup.

## Building

Nothing to build, but it needs a GPU and a working GL 4.3 context — the harness
probes for one and skips the target with a reason rather than producing wrong
numbers. Class G is [docs/RESULTS.md](../../docs/RESULTS.md) §9.
