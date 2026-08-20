/-
  slimebench -- Lean 4 implementation of SPEC-1.

  # What this port is for

  The other eight languages answer "how fast is X". Lean answers a different
  question: what does a proof assistant's compiler do with a workload that is
  nothing but mutable arrays and float arithmetic? It is the only target here
  whose language was not designed with this kind of loop in mind.

  # The three things that decide the numbers

  **Arrays are copy-on-write, not persistent.** `Array.uset` mutates in place
  when the array's reference count is 1 and copies otherwise. A write loop is
  therefore O(n), not O(n^2) -- and if something else still holds the array, it
  copies exactly once and the remainder of the loop is in place again. This was
  measured before the port was written, because the alternative was a port that
  might have been quadratic without anyone noticing.

  **`Float32` is IEEE binary32.** Checked against `round_f32(f64_op(a,b))` --
  which is provably the same thing, since 53 >= 2*24+2 -- over 50 000 pairs
  spanning normals, subnormals and huge values, for `+`, `*` and `/`: zero
  mismatches. So this port computes in f32 directly and needs none of the
  rounding gymnastics Perl and pure Python need.

  **`Array Float32` boxes its elements.** The generated C is full of
  `lean_unbox_float32`: every read dereferences a heap object. Storing the bit
  patterns in an `Array UInt32` instead was measured and is not faster, so the
  simple representation wins by default.

  # Style

  Tail recursion over `USize` indices with `uget`/`uset`, not `for ... let mut`
  over `Nat`. The measured gap between the two is about 30%, and the reason is
  that the do-notation loop turns into a fold over a closure. This is the
  low-level dialect, in the same sense that impl/haskell/src/Sim.hs is -- and
  as there, saying so is part of the result.
-/

import Slimebench.DirTable

namespace Slimebench

/-- SPEC-1 section 5.6. `private` is reproducible per thread count; `binned`
    is bit-identical to a single-threaded run. This port is class S only, so
    the field exists to keep the CLI contract and is not acted on. -/
inductive Reduce where
  | private_
  | binned
  deriving Repr, BEq

inductive Update where
  | serial
  | deferred
  deriving Repr, BEq

structure Config where
  width       : Nat := 1024
  height      : Nat := 1024
  agents      : Nat := 262144
  ticks       : Nat := 1000
  warmup      : Nat := 0
  seed        : UInt32 := 12345
  threads     : Nat := 1
  update      : Update := Update.serial
  reduce      : Reduce := Reduce.private_
  sensorDist  : Float32 := 9.0
  step        : Float32 := 1.0
  deposit     : Float32 := 10.0
  decay       : Float32 := 0.94
  sensorSteps : Nat := 144
  rotSteps    : Nat := 144
  hashEvery   : Nat := 0
  preset      : String := "custom"
  deriving Inhabited

-- ---- PRNG (SPEC-1 section 3.1) --------------------

@[inline] def rotl32 (x : UInt32) (k : UInt32) : UInt32 :=
  (x <<< k) ||| (x >>> (32 - k))

/-- SplitMix32. Returns the new state alongside the output, because Lean has
    no by-reference parameter and threading it is clearer than an `ST.Ref`. -/
@[inline] def splitmix32 (state : UInt32) : UInt32 × UInt32 :=
  let s := state + 0x9E3779B9
  let z := s
  let z := (z ^^^ (z >>> 16)) * 0x21F0AAAD
  let z := (z ^^^ (z >>> 15)) * 0x735A2D97
  (z ^^^ (z >>> 15), s)

/-- xoshiro128++, state as a 4-tuple. -/
@[inline] def xoshiro128pp (s0 s1 s2 s3 : UInt32) :
    UInt32 × UInt32 × UInt32 × UInt32 × UInt32 :=
  let result := rotl32 (s0 + s3) 7 + s0
  let t  := s1 <<< 9
  let s2 := s2 ^^^ s0
  let s3 := s3 ^^^ s1
  let s1 := s1 ^^^ s2
  let s0 := s0 ^^^ s3
  let s2 := s2 ^^^ t
  let s3 := rotl32 s3 11
  (result, s0, s1, s2, s3)

/-- SPEC-1 section 3.2. Exact in f32: `u >>> 8 < 2^24`, and 2^24 is a power of
    two, so both the conversion and the division are exact. -/
@[inline] def rnd01 (u : UInt32) : Float32 :=
  (Float.ofNat (u >>> 8).toNat / 16777216.0).toFloat32

-- ---- state --------------------

structure Sim where
  cfg     : Config
  grid    : Array Float32
  scratch : Array Float32
  dep     : Array Float32
  ax      : Array Float32
  ay      : Array Float32
  adir    : Array UInt32
  /-- Four words per agent, flattened: agent i owns [4i, 4i+4). -/
  arng    : Array UInt32
  log2w   : USize
  xmask   : USize
  ymask   : USize
  nsAgents : Nat := 0
  nsDiffuse : Nat := 0

@[inline] def log2OfPow2 (n : Nat) : USize := (Nat.log2 n).toUSize

-- ---- unchecked array access --------------------

@[inline] def fget (a : Array Float32) (i : USize) : Float32 :=
  if h : i.toNat < a.size then a.uget i h else 0.0

@[inline] def fset (a : Array Float32) (i : USize) (v : Float32) : Array Float32 :=
  if h : i.toNat < a.size then a.uset i v h else a

@[inline] def uget32 (a : Array UInt32) (i : USize) : UInt32 :=
  if h : i.toNat < a.size then a.uget i h else 0

@[inline] def uset32 (a : Array UInt32) (i : USize) (v : UInt32) : Array UInt32 :=
  if h : i.toNat < a.size then a.uset i v h else a

-- ---- initialisation (SPEC-1 section 3.3) --------------------

private partial def initGrid (g : Array Float32) (sm : UInt32) (i n : USize) :
    Array Float32 :=
  if i >= n then g else
  let (u, sm') := splitmix32 sm
  initGrid (fset g i (rnd01 u * 100.0)) sm' (i + 1) n

private partial def initAgents (ax ay : Array Float32) (adir arng : Array UInt32)
    (seed : UInt32) (fw fh : Float32) (i n : USize) :
    Array Float32 × Array Float32 × Array UInt32 × Array UInt32 :=
  if i >= n then (ax, ay, adir, arng) else
  -- One independent stream per agent, so this is order-free.
  let sm0 := seed + 0x9E3779B9 * (UInt32.ofNat i.toNat + 1)
  let (r0, sm1) := splitmix32 sm0
  let (r1, sm2) := splitmix32 sm1
  let (r2, sm3) := splitmix32 sm2
  let (r3, _)   := splitmix32 sm3
  let r0 := if (r0 ||| r1 ||| r2 ||| r3) == 0 then 1 else r0
  let (u1, a0, a1, a2, a3) := xoshiro128pp r0 r1 r2 r3
  let (u2, b0, b1, b2, b3) := xoshiro128pp a0 a1 a2 a3
  let (u3, c0, c1, c2, c3) := xoshiro128pp b0 b1 b2 b3
  let o := i * 4
  let arng := uset32 (uset32 (uset32 (uset32 arng o c0) (o+1) c1) (o+2) c2) (o+3) c3
  initAgents (fset ax i (rnd01 u1 * fw)) (fset ay i (rnd01 u2 * fh))
             (uset32 adir i (u3 % UInt32.ofNat NDIR)) arng
             seed fw fh (i + 1) n

/-- Named `create`, not `mk`: `Sim.mk` is the structure constructor Lean
    generates, and shadowing it is a compile error rather than a style choice. -/
def Sim.create (cfg : Config) : Sim :=
  let cells := cfg.width * cfg.height
  let n := cfg.agents
  let g := initGrid (Array.replicate cells (0.0 : Float32))
                    (cfg.seed ^^^ 0x5BF03635) 0 cells.toUSize
  let (ax, ay, adir, arng) :=
    initAgents (Array.replicate n (0.0 : Float32)) (Array.replicate n (0.0 : Float32))
               (Array.replicate n (0 : UInt32)) (Array.replicate (n * 4) (0 : UInt32))
               cfg.seed (Float32.ofNat cfg.width) (Float32.ofNat cfg.height)
               0 n.toUSize
  { cfg, grid := g
    scratch := Array.replicate cells (0.0 : Float32)
    dep     := Array.replicate cells (0.0 : Float32)
    ax, ay, adir, arng
    log2w := log2OfPow2 cfg.width
    xmask := (cfg.width - 1).toUSize
    ymask := (cfg.height - 1).toUSize }

-- ---- agent pass (SPEC-1 section 5.3) --------------------

/-- SPEC-1 section 2.2. A single correction step is enough because no per-tick
    offset exceeds `sensor_distance` and the grid is at least 512 wide. -/
@[inline] def wrapf (v m : Float32) : Float32 :=
  let v := if v < 0.0 then v + m else v
  if v >= m then v - m else v

/-- The cast to integer is masked as well as wrapped: `wrapf` can return
    exactly `m` through rounding (SPEC-1 2.2). -/
@[inline] def cellOf (x y : Float32) (log2w xmask ymask : USize) : USize :=
  let xi := (x.toFloat.toUInt64.toUSize) &&& xmask
  let yi := (y.toFloat.toUInt64.toUSize) &&& ymask
  (yi <<< log2w) ||| xi

@[inline] def sense (grid : Array Float32) (x y : Float32) (d : USize)
    (sdist fw fh : Float32) (log2w xmask ymask : USize) : Float32 :=
  let sx := wrapf (x + fget cosTable d * sdist) fw
  let sy := wrapf (y + fget sinTable d * sdist) fh
  fget grid (cellOf sx sy log2w xmask ymask)

/-- Advances agent `i` and returns the cell its deposit belongs in, together
    with the updated agent arrays. Returning the cell rather than depositing
    keeps one copy of the rule: `serial` writes into the grid and `deferred`
    into `dep`, and only the caller knows which. -/
@[inline] def agentStep (grid ax ay : Array Float32) (adir arng : Array UInt32)
    (i : USize) (sdist stepLen fw fh : Float32)
    (ss rs : UInt32) (log2w xmask ymask : USize) :
    USize × Array Float32 × Array Float32 × Array UInt32 × Array UInt32 :=
  let d := uget32 adir i
  let x := fget ax i
  let y := fget ay i
  let nd : UInt32 := UInt32.ofNat NDIR
  let dl := (d + nd - ss) % nd
  let dr := (d + ss) % nd
  let fl := sense grid x y dl.toUSize sdist fw fh log2w xmask ymask
  let fc := sense grid x y d.toUSize  sdist fw fh log2w xmask ymask
  let fr := sense grid x y dr.toUSize sdist fw fh log2w xmask ymask
  let o := i * 4
  -- The PRNG is consumed *only* in the dead-end branch, so each agent's stream
  -- position depends on the course of the simulation. That is deliberate and
  -- part of the agent checksum.
  let (d', arng) :=
    if fc >= fl && fc >= fr then
      (d, arng)
    else if fc < fl && fc < fr then
      let (u, s0, s1, s2, s3) :=
        xoshiro128pp (uget32 arng o) (uget32 arng (o+1))
                     (uget32 arng (o+2)) (uget32 arng (o+3))
      let arng := uset32 (uset32 (uset32 (uset32 arng o s0) (o+1) s1) (o+2) s2) (o+3) s3
      (if u &&& 1 == 1 then (d + rs) % nd else (d + nd - rs) % nd, arng)
    else if fl > fr then
      ((d + nd - rs) % nd, arng)
    else
      ((d + rs) % nd, arng)
  -- Rotate first, then move in the new direction (SPEC-1 5.3).
  let x' := wrapf (x + fget cosTable d'.toUSize * stepLen) fw
  let y' := wrapf (y + fget sinTable d'.toUSize * stepLen) fh
  (cellOf x' y' log2w xmask ymask,
   fset ax i x', fset ay i y', uset32 adir i d', arng)

/-- `serial`: the grid is read and written by the same loop, so a later agent
    sees an earlier one's deposit. There is deliberately no second buffer here
    -- passing the grid as both source and target would give it two references,
    and the first write would silently copy it, which is a different
    simulation. -/
private partial def agentSerial (grid ax ay : Array Float32) (adir arng : Array UInt32)
    (i n : USize) (sdist stepLen dep fw fh : Float32) (ss rs : UInt32)
    (log2w xmask ymask : USize) :
    Array Float32 × Array Float32 × Array Float32 × Array UInt32 × Array UInt32 :=
  if i >= n then (grid, ax, ay, adir, arng) else
  let (idx, ax, ay, adir, arng) :=
    agentStep grid ax ay adir arng i sdist stepLen fw fh ss rs log2w xmask ymask
  let grid := fset grid idx (fget grid idx + dep)
  agentSerial grid ax ay adir arng (i + 1) n sdist stepLen dep fw fh ss rs
              log2w xmask ymask

/-- `deferred`: every agent reads the same grid snapshot and deposits into a
    separate buffer, so the pass is order-independent. -/
private partial def agentDeferred (grid target ax ay : Array Float32)
    (adir arng : Array UInt32) (i n : USize)
    (sdist stepLen dep fw fh : Float32) (ss rs : UInt32)
    (log2w xmask ymask : USize) :
    Array Float32 × Array Float32 × Array Float32 × Array UInt32 × Array UInt32 :=
  if i >= n then (target, ax, ay, adir, arng) else
  let (idx, ax, ay, adir, arng) :=
    agentStep grid ax ay adir arng i sdist stepLen fw fh ss rs log2w xmask ymask
  let target := fset target idx (fget target idx + dep)
  agentDeferred grid target ax ay adir arng (i + 1) n sdist stepLen dep fw fh ss rs
                log2w xmask ymask

-- ---- merge and diffusion (SPEC-1 section 5.4) --------------------

/-- `grid[i] += dep[i]; dep[i] = 0`, in one pass. -/
private partial def mergeDep (grid dep : Array Float32) (i n : USize) :
    Array Float32 × Array Float32 :=
  if i >= n then (grid, dep) else
  mergeDep (fset grid i (fget grid i + fget dep i)) (fset dep i 0.0) (i + 1) n

/-- One row of the stencil. The nine additions are in the order SPEC-1 5.4
    prescribes; the multiply by four and the divide by twelve are separate
    rounded operations and must stay that way. -/
private partial def diffuseRow (src dst : Array Float32)
    (rowm row0 rowp x : USize) (w wmask : USize) (decay : Float32) : Array Float32 :=
  if x >= w then dst else
  let xm := (x + wmask) &&& wmask
  let xp := (x + 1) &&& wmask
  let acc := fget src (rowm ||| xm)
  let acc := acc + fget src (rowm ||| x)
  let acc := acc + fget src (rowm ||| xp)
  let acc := acc + fget src (row0 ||| xm)
  let acc := acc + 4.0 * fget src (row0 ||| x)
  let acc := acc + fget src (row0 ||| xp)
  let acc := acc + fget src (rowp ||| xm)
  let acc := acc + fget src (rowp ||| x)
  let acc := acc + fget src (rowp ||| xp)
  diffuseRow src (fset dst (row0 ||| x) (acc / 12.0 * decay)) rowm row0 rowp (x + 1)
             w wmask decay

private partial def diffuseRows (src dst : Array Float32) (y h : USize)
    (log2w w wmask hmask : USize) (decay : Float32) : Array Float32 :=
  if y >= h then dst else
  let rowm := ((y + hmask) &&& hmask) <<< log2w
  let row0 := y <<< log2w
  let rowp := ((y + 1) &&& hmask) <<< log2w
  diffuseRows src (diffuseRow src dst rowm row0 rowp 0 w wmask decay) (y + 1) h
              log2w w wmask hmask decay

-- ---- one tick (SPEC-1 section 5.2) --------------------

/-- The agent pass on its own. Split out from `tick` so the frontend can time
    the two phases separately: every other port reports the split, and the two
    phases have opposite access patterns -- scatter/gather against a dense
    stream -- so a single total hides the more interesting half. -/
def Sim.agentPass (s : Sim) : Sim :=
  let c := s.cfg
  let n := c.agents.toUSize
  let cells := (c.width * c.height).toUSize
  let fw := Float32.ofNat c.width
  let fh := Float32.ofNat c.height
  let ss := UInt32.ofNat c.sensorSteps
  let rs := UInt32.ofNat c.rotSteps

  let (grid, dep, ax, ay, adir, arng) :=
    match c.update with
    | Update.serial =>
      let (g, ax, ay, adir, arng) :=
        agentSerial s.grid s.ax s.ay s.adir s.arng 0 n
                    c.sensorDist c.step c.deposit fw fh ss rs
                    s.log2w s.xmask s.ymask
      (g, s.dep, ax, ay, adir, arng)
    | Update.deferred =>
      let (d, ax, ay, adir, arng) :=
        agentDeferred s.grid s.dep s.ax s.ay s.adir s.arng 0 n
                      c.sensorDist c.step c.deposit fw fh ss rs
                      s.log2w s.xmask s.ymask
      let (g, d) := mergeDep s.grid d 0 cells
      (g, d, ax, ay, adir, arng)

  { s with grid, dep, ax, ay, adir, arng }

/-- Diffusion and decay, then swap. The buffers swap rather than the contents:
    `scratch` holds the new grid and the old grid becomes the next scratch. -/
def Sim.diffusePass (s : Sim) : Sim :=
  let c := s.cfg
  let scratch := diffuseRows s.grid s.scratch 0 c.height.toUSize
                             s.log2w c.width.toUSize s.xmask s.ymask c.decay
  { s with grid := scratch, scratch := s.grid }

def Sim.tick (s : Sim) : Sim := s.agentPass.diffusePass

-- ---- checksums (SPEC-1 section 6) --------------------

private partial def fnvF32 (a : Array Float32) (h : UInt32) (i n : USize) : UInt32 :=
  if i >= n then h else
  fnvF32 a ((h ^^^ (fget a i).toBits) * 0x01000193) (i + 1) n

def Sim.hashGrid (s : Sim) : UInt32 :=
  fnvF32 s.grid 0x811C9DC5 0 (s.grid.size.toUSize)

private partial def fnvAgents (ax ay : Array Float32) (adir : Array UInt32)
    (h : UInt32) (i n : USize) : UInt32 :=
  if i >= n then h else
  let h := (h ^^^ (fget ax i).toBits) * 0x01000193
  let h := (h ^^^ (fget ay i).toBits) * 0x01000193
  let h := (h ^^^ uget32 adir i) * 0x01000193
  fnvAgents ax ay adir h (i + 1) n

def Sim.hashAgents (s : Sim) : UInt32 :=
  fnvAgents s.ax s.ay s.adir 0x811C9DC5 0 (s.cfg.agents.toUSize)

/-- Recomputed from the generated bit arrays, so a corrupted table is caught
    rather than assumed away. -/
def dirtableHash : UInt32 := Id.run do
  let mut h : UInt32 := 0x811C9DC5
  for b in cosBits do h := (h ^^^ b) * 0x01000193
  for b in sinBits do h := (h ^^^ b) * 0x01000193
  pure h

-- ---- rendering (SPEC-1 section 11) --------------------

def Sim.renderGray (s : Sim) (displayMax : Float32) : ByteArray := Id.run do
  let n := s.grid.size
  let mut out := ByteArray.emptyWithCapacity n
  for i in [0:n] do
    let v := (s.grid[i]! * 255.0 / displayMax).toFloat
    let c := if v < 0.0 then 0 else if v > 255.0 then 255 else v.toUInt64.toNat
    out := out.push (UInt8.ofNat c)
  pure out

end Slimebench
