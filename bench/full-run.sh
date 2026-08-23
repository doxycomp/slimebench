#!/usr/bin/env bash
# One consistent measurement of everything, in one sitting.
#
#   bench/full-run.sh [outdir]
#
# The numbers in docs/RESULTS.md accumulated over a dozen sessions on
# different days, which is fine for comparisons drawn *inside* one series and
# misleading for anything drawn across two. This produces one series: every
# class, every language, one machine state, one timestamp.
#
# Run bench/preflight.sh first on a machine this has not seen: it reports what
# is present and which phases will be skipped, rather than letting the run
# discover it ninety minutes in.
#
# On WSL, run it from the Linux filesystem (scripts/stage-wsl.sh) -- on the 9p
# bridge the build times and binary sizes measure the bridge. On native Linux
# staging is unnecessary.
#
# Roughly two hours. Each phase writes its own .jsonl as it finishes, so an
# interrupted run still leaves usable output.

set -u

# A failed cd here would write the entire series into whatever directory
# the caller happened to be in, so it is fatal rather than ignored.
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

# A git worktree checked out from Windows carries a .git file holding a
# Windows path, which git-inside-WSL cannot resolve -- so the manifest recorded
# "commit unknown" and the series could not be tied to a revision. Translate
# the drive letter and ask again.
sb_commit() {
  local c gd drive
  c=$(git rev-parse --short HEAD 2>/dev/null) && { echo "$c"; return; }
  if [ -f .git ]; then
    gd=$(sed -n 's/^gitdir: //p' .git)
    gd=${gd//\\//}          # a Windows gitdir may use backslashes
    case "$gd" in
      [A-Za-z]:/*)
        drive=$(printf '%s' "${gd%%:*}" | tr 'A-Z' 'a-z')
        gd="/mnt/$drive${gd#?:}"
        ;;
    esac
    c=$(git --git-dir="$gd" rev-parse --short HEAD 2>/dev/null) && { echo "$c"; return; }
  fi
  echo unknown
}

# ---- how much measuring to do ---------------------------------------------
# Three profiles, differing only in repetition count. `standard` is what the
# published numbers use. `quick` is for checking that a change did not break a
# port, not for comparing anything. `thorough` is for comparing two machines,
# where the question is whether a 3 % difference is real.
#
#   quick      1 repetition    ~10 min
#   standard   3               ~40 min
#   thorough   5               ~55 min
#
# The estimates come from bench/estimate.py, which prices a plan from a series
# already in results/ rather than from constants written here.
SB_PROFILE=standard
SB_REPS=""
SB_P_REPS=""
DRY=0
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --profile) SB_PROFILE=$2; shift 2 ;;
    --reps)    SB_REPS=$2; shift 2 ;;
    --p-reps)  SB_P_REPS=$2; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    -h|--help)
      sed -n '2,20p' "$0"
      echo
      echo "usage: $0 [--profile quick|standard|thorough] [--reps N]"
      echo "          [--p-reps N] [--dry-run] [OUTDIR]"
      exit 0 ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
case "$SB_PROFILE" in
  quick)    : "${SB_REPS:=1}" ;;
  standard) : "${SB_REPS:=3}" ;;
  thorough) : "${SB_REPS:=5}" ;;
  *) echo "unknown profile: $SB_PROFILE (quick|standard|thorough)" >&2; exit 2 ;;
esac
# Class P used to have no repetitions at all, which made it the one phase
# outside the statistics rule -- and its single-thread row is the denominator
# of every speedup in the table. It follows the same count as everything else
# unless told otherwise; at `standard` that is about ten minutes.
: "${SB_P_REPS:=$SB_REPS}"
export SB_REPS SB_P_REPS SB_PROFILE

if [ "$DRY" = 1 ]; then
  exec python3 bench/estimate.py --reps "$SB_REPS" --p-reps "$SB_P_REPS" \
       --profile "$SB_PROFILE"
fi

OUT=${ARGS[0]:-results/run-$(date +%Y%m%d-%H%M)}
mkdir -p "$OUT"
SB_STARTED=$(date +%s)
echo "==> writing to $OUT  (profile $SB_PROFILE, reps $SB_REPS, class P $SB_P_REPS)"

# Paths that exist on the machine this was written on, added only if they are
# there. A missing one is not an error: the tool is either elsewhere on PATH or
# not installed, and preflight.sh already said which.
[ -d /usr/local/lib ]     && export LD_LIBRARY_PATH=/usr/local/lib:${LD_LIBRARY_PATH:-}
[ -d "$HOME/perl5" ]      && export PERL5LIB="$HOME/perl5/lib/perl5:${PERL5LIB:-}"
[ -d /usr/local/cuda/bin ] && export PATH=/usr/local/cuda/bin:$PATH
[ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"
[ -f "$HOME/.ghcup/env" ] && . "$HOME/.ghcup/env"
# Go and Swift install into $HOME rather than onto the system PATH, and
# without these two lines run.py reports "compiler not installed" and
# quietly drops both languages from class S -- which is how the first
# series to include them came out with seven languages instead of nine.
# Appended, not prepended, and that matters: the Swift toolchain ships its
# own clang 21, which would shadow the system clang 18 and silently change
# what the compiler matrix measured. These two entries exist to add `go`
# and `swiftc`, not to reorder anything already on PATH.
[ -d "$HOME/opt/go/bin" ]        && export PATH="$PATH:$HOME/opt/go/bin"
[ -d "$HOME/opt/swift/usr/bin" ] && export PATH="$PATH:$HOME/opt/swift/usr/bin"
[ -d "$HOME/.elan/bin" ]         && export PATH="$PATH:$HOME/.elan/bin"

# WSL reaches the discrete GPU only through Mesa's D3D12 backend; setting these
# on a native driver would replace a working GL stack with a broken one. The
# label goes into every GPU and render row so a run is attributable to a
# renderer and not just to a machine.
if grep -qi microsoft /proc/version 2>/dev/null; then
  IS_WSL=1
  gpu_env_on()  { export GALLIUM_DRIVER=d3d12 MESA_D3D12_DEFAULT_ADAPTER_NAME=NVIDIA; }
  gpu_env_off() { unset GALLIUM_DRIVER MESA_D3D12_DEFAULT_ADAPTER_NAME; }
  GPU_LABEL="D3D12 (WSL)"
else
  IS_WSL=0
  gpu_env_on()  { :; }
  gpu_env_off() { :; }
  GPU_LABEL="native GL"
fi

# Class R needs a window. Everything else is content headless.
HAVE_DISPLAY=0
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] && HAVE_DISPLAY=1

# Machine and toolchain state, recorded once so the numbers stay attributable.
{
  echo "date        $(date -Is)"
  echo "host        $(uname -srm)"
  echo "cpu         $(awk -F: '/model name/{print $2; exit}' /proc/cpuinfo | xargs)"
  echo "cores       $(nproc) logical"
  echo "mem         $(awk '/MemTotal/{printf "%.0f GiB", $2/1048576}' /proc/meminfo)"
  echo "gcc         $(gcc -dumpversion 2>/dev/null)"
  echo "clang       $(clang -dumpversion 2>/dev/null)"
  echo "rustc       $(rustc --version 2>/dev/null | awk '{print $2}')"
  echo "ghc         $(ghc --numeric-version 2>/dev/null)"
  echo "node        $(node --version 2>/dev/null)"
  echo "python      $(python3 -V 2>&1 | awk '{print $2}')"
  echo "numba       $("${SLIMEBENCH_NUMBAPY:-$HOME/opt/numba/bin/python}" -c 'import numba;print(numba.__version__)' 2>/dev/null)"
  echo "javac       $(javac -version 2>&1 | awk '{print $2}')"
  echo "ocamlopt    $(ocamlopt -version 2>/dev/null)"
  echo "gfortran    $(gfortran -dumpversion 2>/dev/null)"
  echo "dotnet      $(dotnet --version 2>/dev/null)"
  echo "perl        $(perl -e 'print $^V' 2>/dev/null)"
  echo "nvcc        $(nvcc --version 2>/dev/null | awk '/release/{print $6}')"
  echo "gl          $GPU_LABEL"
  echo "display     $([ $HAVE_DISPLAY = 1 ] && echo yes || echo none)"
  # SLIMEBENCH_COMMIT lets the launcher pass it in: the staged copy has no
  # .git, and a run whose numbers cannot be tied to a revision is a
  # transcript rather than a measurement.
  echo "commit      ${SLIMEBENCH_COMMIT:-$(sb_commit)}"
} | tee "$OUT/environment.txt"
echo

phase() { echo; echo "=== $* ==="; }

# ---- 1. cross-language, class S -----------------------------------------
# 256x256 with 16 384 agents: the largest size pure Python and Perl finish in
# seconds, which is the only reason all of them fit in one table.
# --warmup 50 matters for exactly three targets and costs the rest nothing.
# Java, C# and numba are not at full speed on tick 1, and without a warm-up
# their *median* over a hundred cold ticks lands mid-ramp -- which measures
# the compiler rather than the code. Section 6 keeps the cold measurement on
# purpose; this table is the steady state.
phase "class S, all languages, 256x256"
for upd in serial deferred; do
  python3 bench/run.py bench --width 256 --height 256 --agents 16384 \
    --ticks 100 --warmup 50 --reps "$SB_REPS" --update "$upd" \
    --out "$OUT/A-crosslang-$upd.jsonl" || true
done

# ---- 2. compiler matrix --------------------------------------------------
phase "compiler matrix, 1024x1024, 300 ticks"
python3 bench/run.py bench --preset small --ticks 300 --reps "$SB_REPS" \
  --targets c,cpp,rust,haskell,haskell-vector,c-pgo,go,swift,fortran,ocaml,java,csharp \
  --out "$OUT/C-compiler-matrix.jsonl" || true

# ---- 3. class V ----------------------------------------------------------
# Class V has contained two managed runtimes since java-simd and csharp-simd
# were added, so it needs the warm-up for the same reason class S does.
# Without it Java's vector kernel measured 179 ms of diffusion against C's
# 64, which is the ramp and not the vector unit.
phase "class V (SIMD), 1024x1024, 300 ticks"
python3 bench/run.py bench --preset small --ticks 300 --warmup 100 --reps "$SB_REPS" \
  --targets c-simd,cpp-simd,rust-simd,java-simd,csharp-simd,csharp-simd-portable \
  --out "$OUT/G-simd.jsonl" || true

# The agent pass, which is the other 78 to 89 % of a tick and which nothing
# above vectorises. Its own phase and its own file, at four sizes, because the
# interesting part is how the factors move with the grid -- and they move in
# opposite directions. Four targets, so the two changes can be told apart:
# vectorising cuts instructions, spatial ordering cuts the distance between
# the addresses those instructions touch, and at `large` the ordering alone
# beats the vector unit alone.
phase "class V, the agent pass: scalar against vectorised"
: > "$OUT/G-agents.jsonl"
for pre in tiny small medium large; do
  # One compiler and one profile on both sides: the question is what the
  # kernel does, and letting the scalar side bring twelve compiler/profile
  # combinations to a two-row comparison only adds rows to filter out
  # again.
  python3 bench/run.py bench --preset "$pre" --ticks 100 --warmup 20 \
    --reps "$SB_REPS" --update deferred \
    --targets c,c-tiled,c-simd-agents,c-simd-agents-tiled \
    --compilers gcc --profiles o3-native \
    --out "$OUT/G-agents.jsonl" --append || true
done

# The same ordering in C++ and in Rust, at one size. Whether the factor
# survives a different memory model and a different standard library is a
# separate question from how big it is in C, and it needs one preset to
# answer, not four.
python3 bench/run.py bench --preset medium --ticks 100 --warmup 20 \
  --reps "$SB_REPS" --update deferred \
  --targets cpp,cpp-tiled,rust,rust-tiled,go,go-tiled,java,java-tiled,csharp,csharp-tiled,swift,swift-tiled,haskell,haskell-tiled \
  --out "$OUT/G-agents.jsonl" --append || true

# The four-way kernel comparison, reported as ms_diffuse: the agent pass is
# identical in all of them and would dilute the difference. Needs AVX-512 and
# ASM=1; the script says so and writes nothing if either is missing.
phase "class V, diffusion kernels: scalar / intrinsics / assembly"
bench/asm-kernels.sh "$OUT/V-asm-kernels.jsonl" medium 100 || true

# ---- 3b. the style axis --------------------------------------------------
# One language, three ways of writing it, against the C reference. This used
# to be a file copied in from whichever session produced it; the (!) variant
# is now a build profile, so the comparison re-runs with everything else.
phase "Haskell style axis, 1024x1024, 300 ticks"
: > "$OUT/M-haskell-style.jsonl"
style() { # variant-label cmd...
  local label=$1; shift
  local ms hg
  local line
  line=$(timeout 1800 "$@" --preset small --ticks 300 --update deferred 2>/dev/null) || {
    echo "  $label FAILED"; return; }
  ms=$(echo "$line" | awk '/^  total/{print $2}')
  hg=$(echo "$line" | awk '/^  grid_hash/{print $2}')
  [ -z "$ms" ] && { echo "  $label no output"; return; }
  printf '{"schema":1,"impl":"haskell","class":"S","preset":"small","ticks":300,''"update":"deferred","variant":"%s","ms_total":%s,"grid_hash":"%s"}
'     "$label" "$ms" "$hg" >> "$OUT/M-haskell-style.jsonl"
  printf '  %-34s %9s ms  %s
' "$label" "$ms" "$hg"
}
( cd impl/haskell && ./build.sh o2-llvm-safetrig ) >/dev/null 2>&1
style "C reference (clang -O3 -native)" impl/c/build/clang-o3-native/slimebench-headless
style "haskell lowlevel, (!) lookups"   impl/haskell/build/o2-llvm-safetrig/slimebench
style "haskell lowlevel, unsafeAt"      impl/haskell/build/o2-llvm/slimebench
style "haskell idiomatic (vector)"      impl/haskell/build/o2-llvm-vector/slimebench

# ---- 4. class P ----------------------------------------------------------
# One thread sweep per language. Perl runs at `tiny`: `medium` there is hours,
# and the shape of its curve is the datapoint, not a cross-language absolute.
phase "class P, thread sweep"
: > "$OUT/P-parallel.jsonl"
# One place where a lost row is recorded, so the end of the run can count
# them. Everything that gives up on a measurement calls this.
fail() {
  echo "  $* FAILED"
  echo "$*" >> "$OUT/FAILURES.txt"
}

psweep() { # label preset ticks extra-args... -- cmd...
  local label=$1 preset=$2 ticks=$3; shift 3
  local -a red=()
  while [ "$1" != "--" ]; do red+=("$1"); shift; done
  shift
  for t in 1 2 4 8 16 32; do
    for r in "${red[@]}"; do
      [ "$t" = 1 ] && [ "$r" != "${red[0]}" ] && continue
      # `--threads` is passed at every T including 1. Leaving it off and
      # trusting each binary's default is how the Fortran baseline came to be
      # measured 32 threads wide: OpenMP's default is every core, the port
      # only called omp_set_num_threads when asked for more than one, and the
      # JSON still said "threads": 1. The hash matched too -- an atomic add of
      # a constant does not depend on the thread count -- so the row looked
      # perfectly well behaved while being 5x too fast.
      local -a args=(--preset "$preset" --ticks "$ticks" --update deferred
                     --threads "$t")
      [ "$t" -gt 1 ] && [ -n "$r" ] && args+=(--deposit-reduce "$r")
      local j cpu="" rep=0
      local -a js=()
      # The general form of that bug is a row that used more of the machine
      # than its label claims, and no language reports its effective thread
      # count. The kernel is compute-bound, so the OS knows: one thread means
      # about 100 % of one core. Measured on the T=1 rows only, where the
      # answer is unambiguous and the cost is one process per language.
      while [ "$rep" -lt "$SB_P_REPS" ]; do
        rep=$((rep + 1))
        # The CPU check runs once, on the first repetition of the T=1 row:
        # it answers a yes/no question about how many cores the process used,
        # and asking it three times costs three processes for one answer.
        if [ "$t" = 1 ] && [ "$rep" = 1 ]; then
          j=$(timeout 3600 /usr/bin/time -f "SB_CPU %P" "$@" "${args[@]}" \
                --json 2>"$OUT/.cpu" | grep -m1 '^{') || j=""
          cpu=$(sed -n 's/^SB_CPU \([0-9]*\)%$/\1/p' "$OUT/.cpu" | tail -1)
          # Measured twice before it warns. This reads whole-process CPU, so
          # anything else busy on the machine inflates it: Go's T=1 row once
          # came back at 160 % and three clean re-runs of the same command
          # gave 100 %, which cost twenty minutes to establish. A second
          # measurement is one process; a false warning is an investigation.
          if [ -n "$cpu" ] && [ "$cpu" -gt 150 ]; then
            timeout 3600 /usr/bin/time -f "SB_CPU %P" "$@" "${args[@]}" \
              --json 2>"$OUT/.cpu" >/dev/null || true
            cpu2=$(sed -n 's/^SB_CPU \([0-9]*\)%$/\1/p' "$OUT/.cpu" | tail -1)
            if [ -n "$cpu2" ] && [ "$cpu2" -gt 150 ]; then
              msg=$(printf '  %-12s T=1 used %s%% then %s%% CPU -- not one thread' \
                      "$label" "$cpu" "$cpu2")
              echo "$msg" | tee -a "$OUT/WARNINGS.txt"
            else
              printf '  %-12s T=1 read %s%% CPU once, %s%% on re-measure -- noise\n' \
                "$label" "$cpu" "${cpu2:-?}"
            fi
            cpu=$cpu2
          fi
        else
          j=$(timeout 3600 "$@" "${args[@]}" --json 2>/dev/null | grep -m1 '^{') \
            || j=""
        fi
        [ -n "$j" ] && js+=("$j")
      done
      if [ ${#js[@]} -eq 0 ]; then
        fail "class P  $label T=$t $r"
        continue
      fi
      out=$(printf '%s\n' "${js[@]}" | LBL="$label" T="$t" CPU="$cpu" python3 -c "
import sys, json, os
ds = [json.loads(l) for l in sys.stdin if l.strip()]
ms = [d['ms_total'] for d in ds]
d = min(ds, key=lambda x: x['ms_total'])
d['lang_label'] = os.environ['LBL']; d['threads'] = int(os.environ['T'])
d['reps'] = len(ms)
d['ms_total_reps'] = [round(v, 4) for v in ms]
d['ms_total_spread'] = round((max(ms) - min(ms)) / min(ms), 4) if min(ms) > 0 else 0.0
# A thread count that changes the answer is the thing class P exists to rule
# out, so disagreement between repetitions of one configuration is recorded
# rather than averaged away.
d['deterministic_across_reps'] = len({x['grid_hash'] for x in ds}) == 1
if os.environ.get('CPU'): d['cpu_pct'] = int(os.environ['CPU'])
print(json.dumps(d))")
      echo "$out" >> "$OUT/P-parallel.jsonl"
      echo "$out" | LBL="$label" T="$t" R="$r" python3 -c "
import sys, json, os
d = json.load(sys.stdin)
sp = d['ms_total_spread'] * 100
mark = ' noisy' if sp > 5 else ''
print('  %-12s T=%-3s %-8s %8.0f ms  %4.1f%%%s'
      % (os.environ['LBL'], os.environ['T'], os.environ['R'],
         d['ms_total'], sp, mark))"
    done
  done
}
psweep c       medium 100 binned private -- impl/c/build/gcc-o3-native/slimebench-headless
psweep cpp     medium 100 binned private -- impl/cpp/build/g++-o3-native/slimebench-headless
psweep rust    medium 100 binned private -- impl/rust/build/release-native-unchecked/slimebench
psweep haskell medium 100 binned private -- impl/haskell/build/o2-llvm/slimebench
psweep ts      medium 100 binned private -- node --experimental-strip-types --no-warnings impl/ts/src/main-node.ts
psweep python  medium 100 binned private -- python3 impl/python/slimebench_numpy.py
psweep go      medium 100 binned private -- impl/go/build/nobounds/slimebench
psweep swift   medium 100 binned private -- impl/swift/build/unchecked/slimebench
psweep java    medium 100 binned private -- impl/java/build/default/slimebench
psweep csharp  medium 100 binned private -- impl/csharp/build/aot/slimebench
# Fortran has one strategy, not two: an atomic add, which is bit-exact here
# because the deposit is a constant. The empty reduction argument is that.
psweep fortran medium 100 ""              -- impl/fortran/build/openmp/slimebench
psweep perl    tiny    20 ""              -- perl impl/perl/slimebench.pl

# The free-threading experiment: {GIL, no-GIL} x {threads, processes} x T,
# everything else held fixed. Skipped with a note if no free-threaded
# interpreter is installed -- the GIL half alone is not the measurement.
phase "class P, CPython free-threading matrix"
bench/gil-matrix.sh "$OUT/P-gil-matrix.jsonl" small 100 || true

# The interpreter's share, isolated: slimebench_pure.py and
# slimebench_numba.py are the same source shape, so the ratio between them is
# CPython and nothing else. The same phase measures how long the agent hash
# keeps calling a fast-math build conformant after the grid hash has stopped.
phase "class S, numba: the interpreter, the JIT, and what fast-math breaks"
bench/numba-jit.sh "$OUT/S-numba-jit.txt" || true

# The JVM is the only target here whose speed depends on how long it has been
# running, and the only one that can be told to stop compiling -- which makes
# -Xint directly comparable to CPython on the identical algorithm. Both halves
# in one phase.
phase "class S, JVM: the warm-up ramp and the two interpreters"
bench/jvm-warmup.sh "$OUT/S-jvm-warmup.txt" || true

# .NET compiles the identical source through a JIT and ahead of time to a
# native binary. No other language here can be asked that question.
phase "class S, .NET: what runtime profile information is worth"
bench/dotnet-aot.sh "$OUT/S-dotnet-aot.txt" || true

# Six of the fourteen languages are collected. Whether any collector is doing
# anything is a property of the workload, and the answer belongs in the series
# rather than in a caveat.
phase "garbage collectors: is any of them working?"
bench/gc-stats.sh "$OUT/S-gc-stats.txt" || true

# Java and C# both stop scaling before 32 threads and section 5 attributed it
# to the barrier. All four class P languages can now report their own
# work/barrier split, which is what settles it -- differently for each of them.
phase "class P, where the managed runtimes lose it"
bench/barriers.sh "$OUT/P-barriers.txt" || true

# ---- 5. class G ----------------------------------------------------------
phase "class G, every preset"
: > "$OUT/H-gpu.jsonl"
gpu() { # label cmd...
  local label=$1; shift
  for p in tiny small medium large huge; do
    local j
    j=$(timeout 3600 "$@" --preset "$p" --ticks 100 --update deferred --json 2>/dev/null \
        | grep -m1 '^{') || continue
    [ -z "$j" ] && continue
    echo "$j" | LBL="$label" python3 -c "
import sys, json, os
d = json.load(sys.stdin); d['lang_label'] = os.environ['LBL']
print(json.dumps(d))" >> "$OUT/H-gpu.jsonl"
    printf "  %-14s %-7s %8.0f ms  %9.0f MCUPS\n" "$label" "$p" \
      "$(echo "$j" | python3 -c 'import sys,json; print(json.load(sys.stdin)["ms_total"])')" \
      "$(echo "$j" | python3 -c 'import sys,json; print(json.load(sys.stdin)["mcups"])')"
  done
}
gpu_env_on
gpu "cuda"        impl/cuda/build/default/slimebench-cuda
if [ "$HAVE_DISPLAY" = 1 ]; then
  gpu "gl43 C"      impl/glcompute/build/default/slimebench-gl
  gpu "gl43 Python" python3 impl/pygl/slimebench_pygl.py
else
  echo "  (GL hosts skipped: no display, and a GL context needs one)"
fi
gpu_env_off

# ---- 6. class R ----------------------------------------------------------
phase "class R, both backends, both renderers"
: > "$OUT/Q-render.jsonl"
render() { # lang label cmd...
  local lang=$1 label=$2; shift 2
  local n=200; [ "$lang" = perl ] && n=20
  local j
  # --json already turns the HUD off everywhere it exists; passing --no-hud
  # as well makes that explicit in the command line, so a frame that drew
  # an overlay could not be mistaken for one of these numbers. Only the
  # three languages that have a HUD accept the flag -- SPEC-1 section 10
  # says the others must reject it, and they do.
  local -a hud=()
  case "$lang" in c|cpp|rust) hud=(--no-hud);; esac
  j=$(timeout 900 "$@" --preset small --ticks "$n" --freeze-sim --json "${hud[@]}" 2>/dev/null \
      | grep -m1 '^{') || { fail "class R  $label ($RLABEL)"; return; }
  [ -z "$j" ] && { fail "class R  $label ($RLABEL): no json"; return; }
  echo "$j" | RL="$RLABEL" python3 -c "
import sys, json, os
d = json.load(sys.stdin); d['renderer'] = os.environ['RL']
print(json.dumps(d))" >> "$OUT/Q-render.jsonl"
  echo "$j" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(f\"  {d['impl']:8s} {d['backend']:8s} {d['ms_render_median']:9.3f} ms  {d['fps_equiv']:8.1f} fps\")"
}
render_all() {
  render c       c-sdl2      impl/c/build/gcc-o3-native/slimebench-sdl2
  render c       c-raylib    impl/c/build/gcc-o3-native/slimebench-raylib
  render cpp     cpp-sdl2    impl/cpp/build/g++-o3-native/slimebench-sdl2
  render cpp     cpp-raylib  impl/cpp/build/g++-o3-native/slimebench-raylib
  render rust    rs-sdl2     impl/rust/target/release/slimebench-sdl2
  render rust    rs-raylib   impl/rust/target/release/slimebench-raylib
  render haskell hs-sdl2     impl/haskell/build/o2-sdl2/slimebench-sdl2
  render haskell hs-raylib   impl/haskell/build/o2-raylib/slimebench-raylib
  render python  py-pygame   python3 impl/python/slimebench_pygame.py
  render python  py-raylib   python3 impl/python/slimebench_pyray.py
  render perl    pl-sdl2     perl impl/perl/slimebench-render.pl --backend sdl2
  render perl    pl-raylib   perl impl/perl/slimebench-render.pl --backend raylib
}
if [ "$HAVE_DISPLAY" != 1 ]; then
  echo "  (skipped: class R needs a window and there is no display)"
elif [ "$IS_WSL" = 1 ]; then
  # Two renderers are worth measuring here only because WSL's default is a
  # software rasteriser -- which is exactly how the first published class R
  # numbers came to be software numbers without anyone noticing.
  echo "  -- llvmpipe (software) --"
  gpu_env_off
  RLABEL="llvmpipe" render_all
  echo "  -- discrete GPU via Mesa D3D12 --"
  gpu_env_on
  RLABEL="D3D12 NVIDIA" render_all
  gpu_env_off
else
  echo "  -- $GPU_LABEL --"
  RLABEL="$GPU_LABEL" render_all
  # The software comparison is still informative; LIBGL_ALWAYS_SOFTWARE gets
  # it without the WSL detour.
  echo "  -- llvmpipe (software) --"
  LIBGL_ALWAYS_SOFTWARE=1 RLABEL="llvmpipe" render_all
fi

echo
echo "==> done. $(cat "$OUT"/*.jsonl 2>/dev/null | wc -l) rows in $OUT"

# An empty result file is the quietest way for this suite to fail: the phase
# runs, every target inside it dies, and the only symptom is a table that is
# shorter than it was last time. Named here, once, at the end.
empty=0
for f in "$OUT"/*.jsonl; do
  [ -e "$f" ] || continue
  n=$(grep -c '' "$f" 2>/dev/null || true)
  if [ "${n:-0}" -eq 0 ]; then
    echo "  EMPTY  $(basename "$f")"
    empty=$((empty + 1))
  fi
done

# Written as `if`, not `[ -f x ] && n=...`: under `set -e` the second form
# aborts the script when the file is absent, which is the success case.
nfail=0
if [ -f "$OUT/FAILURES.txt" ]; then
  nfail=$(grep -c '' "$OUT/FAILURES.txt" || true)
fi
nwarn=0
if [ -f "$OUT/WARNINGS.txt" ]; then
  nwarn=$(grep -c '' "$OUT/WARNINGS.txt" || true)
fi

# What the run cost, recorded so the next dry run can price a plan from a
# measurement instead of from a constant somebody typed. Wall clock, not the
# sum of the measurements: builds, warm-up and process start-up are most of
# the difference and a plan has to pay for them too.
SB_ELAPSED=$(( $(date +%s) - SB_STARTED ))
python3 - "$OUT" "$SB_PROFILE" "$SB_REPS" "$SB_P_REPS" "$SB_ELAPSED" <<'PYEOF' \
  > "$OUT/run.json"
import json, sys
out, profile, reps, preps, elapsed = sys.argv[1:6]
print(json.dumps({"out": out, "profile": profile, "reps": int(reps),
                  "p_reps": int(preps), "wall_seconds": int(elapsed)},
                 indent=2))
PYEOF
printf "    wall clock   %d min %d s\n" $((SB_ELAPSED / 60)) $((SB_ELAPSED % 60))
echo "    failures     $nfail"
echo "    empty files  $empty"
echo "    warnings     $nwarn"
if [ "$nfail" -gt 0 ]; then
  echo
  echo "  the failures were:"
  sed 's/^/    /' "$OUT/FAILURES.txt"
fi
echo
ls -1 "$OUT"
[ "$nfail" -eq 0 ] && [ "$empty" -eq 0 ]
