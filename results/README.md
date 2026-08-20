# Measurement data

```
run-YYYYmmdd-HHMM/    one complete measurement series
archive/              the individual measurements the project grew out of
```

## `run-*/` — the current numbers

Each directory is **one** run over the whole matrix, produced with

```bash
bench/full-run.sh          # native, or from /mnt/c with the 9p caveat
scripts/stage-wsl.sh && bench/full-run.sh   # WSL2, for clean build times
```

Every table and chart in [`docs/RESULTS.md`](../docs/RESULTS.md) comes from the
most recent one — currently `run-20260820-0330` — generated with
`bench/tables.py` and `bench/charts.py`. `environment.txt` records the machine,
the toolchain versions and the commit: a measurement that cannot be tied to a
revision is a transcript.

| File | Contents |
|---|---|
| `A-crosslang-{serial,deferred}.jsonl` | class S, all languages, 256² |
| `C-compiler-matrix.jsonl` | compiler × profile, 1024²/300 |
| `G-simd.jsonl` | class V (intrinsics), 1024²/300 |
| `V-asm-kernels.jsonl` | class V, diffusion kernels scalar/intrinsics/assembly |
| `M-haskell-style.jsonl` | the style axis: C reference and three Haskell versions |
| `P-parallel.jsonl` | class P, thread sweep per language |
| `P-gil-matrix.jsonl` | CPython 3.12 vs 3.14t × threads vs processes |
| `H-gpu.jsonl` | class G, all five presets, three hosts |
| `Q-render.jsonl` | class R, both backends × both renderers |
| `environment.txt` | machine, toolchains, commit |
| `run.log` | the full console transcript of the run |

## `archive/` — how it got here

The letter files are the individual measurements from the sessions in which the
corresponding findings appeared. They are **not** comparable with one another:
different days, different machine state, in places different source revisions.
That is exactly what prompted `full-run.sh`.

They stay in the tree because a few findings in RESULTS.md are only evidenced
here and are not repeated by the full run — the barrier variants, the rejected
parallel prefix sum, the PGO measurement, the `threads::shared` comparison for
Perl. If you want to re-derive one of those numbers, it is here; if you want to
compare languages, use `run-*/`.

One file is deliberately wrong and stays that way: `H-gpu.jsonl` holds the GL
compute figures from before the 2D dispatch fix, where the diffusion pass was
silently skipped. It is the evidence behind the entry in
[RESULTS.md §12](../docs/RESULTS.md#12-where-i-was-wrong).

Older `run-*/` directories are left in place. They are internally consistent
and therefore still usable; they are simply no longer the ones the document
quotes.

`P-lean-tasks.txt` is the Lean class P experiment — three ownership shapes
against the serial run, at two thread-pool sizes. It is a text table rather
than JSONL because nothing generates a chart from it and inventing a schema
for one experiment would be worse than reading it.

The root directory also holds a few individual measurements that belong to no
series and are not meant to: `V-asm-kernels-reps9.jsonl`, for instance, is the
control measurement with nine repetitions instead of three, used to check
whether the assembly kernel's lead is noise (§7).
