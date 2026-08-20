/-
  Can Lean tasks make this workload faster?

  This is the class P question for `impl/lean`, and it is not the question the
  other ports face. Everywhere else the obstacle is a barrier: workers share
  one grid and coordinate. Lean has no shared mutable grid to coordinate over.
  Its arrays are reference-counted and copy-on-write, so two tasks holding the
  same destination buffer would each copy it on the first write. The design
  space is therefore about *ownership*, not about synchronisation, and this
  program measures the three shapes that ownership allows.

    A  striped, boxed     grid stored as `Array (Array Float32)`, one block per
                          task, resolved per row
    B  sliced, boxed      one flat shared `Array Float32`, each task builds its
                          own row block, parent concatenates
    C  sliced, unboxed    the same, but storage is the f32 *bit pattern* in an
                          `Array UInt32`

  A and B differ in layout. B and C differ only in whether an element is a heap
  object. That single difference is what the experiment is really about: when
  an array is shared with a task, Lean marks it multi-threaded and reference
  counts it atomically -- and if the elements are boxed, that is nine atomic
  read-modify-writes per cell, on top of the arithmetic.

  Every shape prints the grid hash. A parallel result that does not match the
  serial one is not a result, and the hash is what says so.

  Run it with `bench/lean-tasks.sh`.
-/

import Slimebench.Sim

namespace Slimebench.Bench

def W : Nat := 512
def H : Nat := 512
def N : Nat := W * H
def TICKS : Nat := 20
def WU : USize := 512
def WMU : USize := 511
def HMASK : Nat := H - 1

/-- Storage as f32 bit patterns in a scalar array: no per-element heap object,
    so nothing per element to reference count. -/
@[inline] def bget (a : Array UInt32) (i : USize) : Float32 :=
  Float32.ofBits (if h : i.toNat < a.size then a.uget i h else 0)

@[inline] def bset (a : Array UInt32) (i : USize) (v : Float32) : Array UInt32 :=
  if h : i.toNat < a.size then a.uset i v.toBits h else a

/-- Rows `[y0, y1)` of the SPEC-1 5.4 stencil, written into a destination whose
    row 0 corresponds to global row `yBase`. -/
partial def rowsBoxed (src dst : Array Float32) (y y1 : Nat) (decay : Float32)
    (yBase : Nat) : Array Float32 :=
  if y >= y1 then dst else
  let rowm := (((y + HMASK) &&& HMASK) * W).toUSize
  let row0 := (y * W).toUSize
  let rowp := (((y + 1) &&& HMASK) * W).toUSize
  let localRow := ((y - yBase) * W).toUSize
  let rec inner (d : Array Float32) (x : USize) : Array Float32 :=
    if x >= WU then d else
    let xm := (x + WMU) &&& WMU
    let xp := (x + 1) &&& WMU
    let acc := fget src (rowm ||| xm)
    let acc := acc + fget src (rowm ||| x)
    let acc := acc + fget src (rowm ||| xp)
    let acc := acc + fget src (row0 ||| xm)
    let acc := acc + 4.0 * fget src (row0 ||| x)
    let acc := acc + fget src (row0 ||| xp)
    let acc := acc + fget src (rowp ||| xm)
    let acc := acc + fget src (rowp ||| x)
    let acc := acc + fget src (rowp ||| xp)
    inner (fset d (localRow ||| x) (acc / 12.0 * decay)) (x + 1)
  rowsBoxed src (inner dst 0) (y + 1) y1 decay yBase

partial def rowsUnboxed (src dst : Array UInt32) (y y1 : Nat) (decay : Float32)
    (yBase : Nat) : Array UInt32 :=
  if y >= y1 then dst else
  let rowm := (((y + HMASK) &&& HMASK) * W).toUSize
  let row0 := (y * W).toUSize
  let rowp := (((y + 1) &&& HMASK) * W).toUSize
  let localRow := ((y - yBase) * W).toUSize
  let rec inner (d : Array UInt32) (x : USize) : Array UInt32 :=
    if x >= WU then d else
    let xm := (x + WMU) &&& WMU
    let xp := (x + 1) &&& WMU
    let acc := bget src (rowm ||| xm)
    let acc := acc + bget src (rowm ||| x)
    let acc := acc + bget src (rowm ||| xp)
    let acc := acc + bget src (row0 ||| xm)
    let acc := acc + 4.0 * bget src (row0 ||| x)
    let acc := acc + bget src (row0 ||| xp)
    let acc := acc + bget src (rowp ||| xm)
    let acc := acc + bget src (rowp ||| x)
    let acc := acc + bget src (rowp ||| xp)
    inner (bset d (localRow ||| x) (acc / 12.0 * decay)) (x + 1)
  rowsUnboxed src (inner dst 0) (y + 1) y1 decay yBase

def hashBoxed (a : Array Float32) : UInt32 := Id.run do
  let mut h : UInt32 := 0x811C9DC5
  for i in [0:N] do h := (h ^^^ a[i]!.toBits) * 0x01000193
  pure h

def hashUnboxed (a : Array UInt32) : UInt32 := Id.run do
  let mut h : UInt32 := 0x811C9DC5
  for i in [0:N] do h := (h ^^^ a[i]!) * 0x01000193
  pure h

def hex8 (u : UInt32) : String :=
  let s := String.ofList (Nat.toDigits 16 u.toNat)
  "0x" ++ "".pushn '0' (8 - s.length) ++ s.toUpper

def seedBits : Array UInt32 :=
  (Array.range N).map fun i => (((i % 97).toFloat / 3.0)).toFloat32.toBits

def seedBoxed : Array Float32 := seedBits.map Float32.ofBits

def decay : Float32 := 0.94

/-- Every timing goes through this. A pure value between two clock reads gets
    floated to its use site and the measurement comes out as zero -- which it
    did, repeatedly, while this file was being written. -/
def timed {α : Type} (act : IO α) (force : α → UInt32) : IO (Float × UInt32) := do
  let sink ← IO.mkRef (0 : UInt32)
  let t0 ← IO.monoNanosNow
  let v ← act
  sink.set (force v)
  let h ← sink.get
  let t1 ← IO.monoNanosNow
  pure ((t1 - t0).toFloat / 1e6, h)

def main : IO Unit := do
  let nt ← IO.getEnv "LEAN_NUM_THREADS"
  IO.println s!"# Lean tasks on the SPEC-1 diffusion pass, {W}x{H}, {TICKS} ticks"
  IO.println s!"# LEAN_NUM_THREADS={nt}"
  IO.println ""

  let (serMs, serHash) ← timed (do
    let mut a := seedBoxed
    let mut b : Array Float32 := Array.replicate N 0.0
    for _ in [0:TICKS] do
      let nb := rowsBoxed a b 0 H decay 0
      b := a; a := nb
    pure a) hashBoxed
  IO.println s!"serial (boxed)      {serMs / TICKS.toFloat} ms/tick   1.00 x   {hex8 serHash}"

  -- B: shared flat boxed array, per-task slice, concatenate.
  for t in [2, 4, 8, 16] do
    let rpb := H / t
    let (ms, h) ← timed (do
      let mut g := seedBoxed
      for _ in [0:TICKS] do
        let tasks ← (List.range t).mapM fun bi =>
          IO.asTask (do
            let lo := bi * rpb
            let hi := if bi + 1 == t then H else lo + rpb
            let r ← IO.mkRef (Array.replicate 0 (0.0 : Float32))
            r.set (rowsBoxed g (Array.replicate ((hi - lo) * W) (0.0 : Float32)) lo hi decay lo)
            r.get)
        let mut out : Array Float32 := Array.emptyWithCapacity N
        for tk in tasks do
          match ← IO.wait tk with
          | Except.ok p => out := out ++ p
          | Except.error e => throw e
        g := out
      pure g) hashBoxed
    IO.println s!"sliced boxed T={t}   {ms / TICKS.toFloat} ms/tick   {serMs / ms} x   {hex8 h}"

  -- C: the same, with unboxed storage.
  let (serU, serUHash) ← timed (do
    let mut a := seedBits
    let mut b : Array UInt32 := Array.replicate N 0
    for _ in [0:TICKS] do
      let nb := rowsUnboxed a b 0 H decay 0
      b := a; a := nb
    pure a) hashUnboxed
  IO.println ""
  IO.println s!"serial (unboxed)    {serU / TICKS.toFloat} ms/tick   1.00 x   {hex8 serUHash}"

  for t in [2, 4, 8, 16] do
    let rpb := H / t
    let (ms, h) ← timed (do
      let mut g := seedBits
      for _ in [0:TICKS] do
        let tasks ← (List.range t).mapM fun bi =>
          IO.asTask (do
            let lo := bi * rpb
            let hi := if bi + 1 == t then H else lo + rpb
            let r ← IO.mkRef (Array.replicate 0 (0 : UInt32))
            r.set (rowsUnboxed g (Array.replicate ((hi - lo) * W) (0 : UInt32)) lo hi decay lo)
            r.get)
        let mut out : Array UInt32 := Array.emptyWithCapacity N
        for tk in tasks do
          match ← IO.wait tk with
          | Except.ok p => out := out ++ p
          | Except.error e => throw e
        g := out
      pure g) hashUnboxed
    IO.println s!"sliced unboxed T={t} {ms / TICKS.toFloat} ms/tick   {serU / ms} x   {hex8 h}"

end Slimebench.Bench

def main : IO Unit := Slimebench.Bench.main
