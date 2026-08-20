/-
  slimebench -- Lean 4 headless benchmark (class S).

  The CLI contract is SPEC-1 section 10, including the part that matters most:
  an unknown flag exits 2 rather than being ignored. Silently ignored flags
  have ruined more benchmarks than any compiler bug, and a harness that runs
  `--simd` against a build with no vector kernel and reports the scalar number
  is exactly that failure.
-/

import Slimebench.Sim

open Slimebench

def usage : String :=
"usage: slimebench [options]   (slimebench SPEC-1)
  --preset NAME        tiny|small|medium|large|huge|browser
  --width N --height N powers of two
  --agents N  --ticks N  --warmup N  --seed N
  --update MODE        serial|deferred
  --threads N
  --deposit-reduce M   private|binned  (SPEC-1 5.6)
  --sensor-dist F  --sensor-steps N  --rot-steps N
  --step F  --deposit F  --decay F
  --headless  --json  --hash-every N
  -h, --help"

def fail (msg : String) : IO α := do
  (← IO.getStderr).putStrLn s!"error: {msg}\n{usage}"
  IO.Process.exit 2

def preset? (n : String) : Option (Nat × Nat × Nat × Nat) :=
  match n with
  | "tiny"    => some (512, 512, 65536, 1000)
  | "small"   => some (1024, 1024, 262144, 1000)
  | "medium"  => some (2048, 2048, 1048576, 1000)
  | "large"   => some (4096, 4096, 4194304, 500)
  | "huge"    => some (8192, 8192, 16777216, 100)
  | "browser" => some (1024, 1024, 262144, 0)
  | _         => none

/-- Scan a run of decimal digits: returns the value, how many there were, and
    the rest of the input. -/
private def scanDigits : List Char → Nat → Nat → Nat × Nat × List Char
  | c :: r, acc, n =>
    if '0' ≤ c && c ≤ '9' then scanDigits r (acc * 10 + (c.toNat - 48)) (n + 1)
    else (acc, n, c :: r)
  | [], acc, n => (acc, n, [])

/-- Lean core has no `String.toFloat?`, and pulling in a JSON library to read
    `--decay 0.94` would be a poor trade. Handles sign, integer part, fraction
    and exponent, which is everything the CLI contract can present. -/
def parseFloat? (str : String) : Option Float :=
  let cs := str.toList
  let (neg, cs) := match cs with
    | '-' :: r => (true, r)
    | '+' :: r => (false, r)
    | _        => (false, cs)
  let (ip, ipLen, cs) := scanDigits cs 0 0
  let (fracVal, fracLen, cs) := match cs with
    | '.' :: r => scanDigits r 0 0
    | _        => (0, 0, cs)
  let (ex, cs) := match cs with
    | 'e' :: r | 'E' :: r =>
      let (esign, r) := match r with
        | '-' :: t => ((-1 : Int), t)
        | '+' :: t => ((1 : Int), t)
        | _        => ((1 : Int), r)
      let (ev, evLen, r) := scanDigits r 0 0
      (if evLen == 0 then none else some (esign * (ev : Int)), r)
    | _ => (some (0 : Int), cs)
  match ex with
  | none => none
  | some ex =>
    -- Reject "", "abc", "1.2x": a silently accepted garbage value is worse
    -- than an error, and SPEC-1 section 10 says so about flags generally.
    if !cs.isEmpty || (ipLen == 0 && fracLen == 0) then none else
    let mag := Float.ofNat ip + Float.ofNat fracVal / (10.0 ^ Float.ofNat fracLen)
    let scaled :=
      if ex == 0 then mag
      else if ex > 0 then mag * (10.0 ^ Float.ofNat ex.toNat)
      else mag / (10.0 ^ Float.ofNat (-ex).toNat)
    some (if neg then -scaled else scaled)

structure Opts where
  cfg  : Config := {}
  json : Bool := false

partial def parse (args : List String) (o : Opts) : IO Opts := do
  match args with
  | [] => pure o
  | a :: rest =>
    let needN (k : String) (xs : List String) : IO (Nat × List String) :=
      match xs with
      | v :: r => match v.toNat? with
                  | some n => pure (n, r)
                  | none   => fail s!"'{v}' is not an integer"
      | []     => fail s!"{k} requires a value"
    let needF (k : String) (xs : List String) : IO (Float32 × List String) :=
      match xs with
      | v :: r => match parseFloat? v with
                  | some f => pure (f.toFloat32, r)
                  | none   => fail s!"'{v}' is not a number"
      | []     => fail s!"{k} requires a value"
    let needS (k : String) (xs : List String) : IO (String × List String) :=
      match xs with
      | v :: r => pure (v, r)
      | []     => fail s!"{k} requires a value"
    match a with
    | "-h" | "--help" => IO.println usage; IO.Process.exit 0
    | "--json"        => parse rest { o with json := true }
    | "--headless"    => parse rest o
    | "--preset" =>
      let (v, r) ← needS a rest
      match preset? v with
      | none => fail s!"unknown preset '{v}'"
      | some (w, h, n, t) =>
        parse r { o with cfg := { o.cfg with width := w, height := h, agents := n,
                                             ticks := t, preset := v } }
    | "--width"  => let (v, r) ← needN a rest
                    parse r { o with cfg := { o.cfg with width := v, preset := "custom" } }
    | "--height" => let (v, r) ← needN a rest
                    parse r { o with cfg := { o.cfg with height := v, preset := "custom" } }
    | "--agents" => let (v, r) ← needN a rest
                    parse r { o with cfg := { o.cfg with agents := v, preset := "custom" } }
    | "--ticks"  => let (v, r) ← needN a rest; parse r { o with cfg := { o.cfg with ticks := v } }
    | "--warmup" => let (v, r) ← needN a rest; parse r { o with cfg := { o.cfg with warmup := v } }
    | "--seed"   => let (v, r) ← needN a rest
                    parse r { o with cfg := { o.cfg with seed := UInt32.ofNat v } }
    | "--threads" => let (v, r) ← needN a rest; parse r { o with cfg := { o.cfg with threads := v } }
    | "--hash-every" => let (v, r) ← needN a rest
                        parse r { o with cfg := { o.cfg with hashEvery := v } }
    | "--sensor-steps" => let (v, r) ← needN a rest
                          parse r { o with cfg := { o.cfg with sensorSteps := v } }
    | "--rot-steps" => let (v, r) ← needN a rest
                       parse r { o with cfg := { o.cfg with rotSteps := v } }
    | "--sensor-dist" => let (v, r) ← needF a rest
                         parse r { o with cfg := { o.cfg with sensorDist := v } }
    | "--step"    => let (v, r) ← needF a rest; parse r { o with cfg := { o.cfg with step := v } }
    | "--deposit" => let (v, r) ← needF a rest; parse r { o with cfg := { o.cfg with deposit := v } }
    | "--decay"   => let (v, r) ← needF a rest; parse r { o with cfg := { o.cfg with decay := v } }
    | "--display-max" | "--dump-grid" => let (_, r) ← needS a rest; parse r o
    | "--update" =>
      let (v, r) ← needS a rest
      match v with
      | "serial"   => parse r { o with cfg := { o.cfg with update := Update.serial } }
      | "deferred" => parse r { o with cfg := { o.cfg with update := Update.deferred } }
      | _ => fail "--update must be serial|deferred"
    | "--deposit-reduce" =>
      let (v, r) ← needS a rest
      match v with
      | "private" => parse r { o with cfg := { o.cfg with reduce := Reduce.private_ } }
      | "binned"  => parse r { o with cfg := { o.cfg with reduce := Reduce.binned } }
      | _ => fail "--deposit-reduce must be private|binned"
    | "--simd" => fail "this target has no vectorised kernel"
    | "--no-simd" => parse rest o
    | _ => fail s!"unknown argument '{a}'"

def hex8 (u : UInt32) : String :=
  let s := String.ofList (Nat.toDigits 16 u.toNat)
  "0x" ++ "".pushn '0' (8 - s.length) ++ s.toUpper

/-- Median and p99 of the per-tick times, matching what the other ports report:
    a mean alone hides the outliers, and the outliers are informative. -/
def stats (xs : Array Float) : Float × Float × Float :=
  if xs.isEmpty then (0.0, 0.0, 0.0) else
  let sorted := xs.qsort (· < ·)
  let n := sorted.size
  let mean := (xs.foldl (· + ·) 0.0) / n.toFloat
  let median := sorted[n / 2]!
  let p99i := min (n - 1) (Float.toUInt64 (n.toFloat * 0.99)).toNat
  (mean, median, sorted[p99i]!)

def main (argv : List String) : IO UInt32 := do
  let o ← parse argv {}
  let c := o.cfg
  if c.threads > 1 then
    let e ← IO.getStderr
    e.putStrLn "error: this target is class S only (--threads 1)"
    return 2

  let mut s := Sim.create c
  let sink ← IO.mkRef (0.0 : Float32)
  let stderr ← IO.getStderr

  for _ in [0:c.warmup] do
    s := s.tick

  let mut tickMs : Array Float := Array.emptyWithCapacity c.ticks
  let mut nsAgents : Nat := 0
  let mut nsDiffuse : Nat := 0
  let t0 ← IO.monoNanosNow
  for t in [0:c.ticks] do
    let a ← IO.monoNanosNow
    -- Timed separately, and the intermediate is forced by the clock read
    -- between them: the two phases have opposite access patterns and a single
    -- total would hide the more interesting half.
    s := s.agentPass
    -- Reading one cell forces the pass. Without it the phase is not evaluated
    -- until something downstream needs the grid, and the clock reads then
    -- bracket nothing: the first version of this loop reported 0.014 ms of
    -- agent work inside a 167 ms run.
    sink.set (fget s.grid 0)
    let _ ← sink.get
    let m ← IO.monoNanosNow
    s := s.diffusePass
    sink.set (fget s.grid 0)
    let _ ← sink.get
    let b ← IO.monoNanosNow
    nsAgents := nsAgents + (m - a)
    nsDiffuse := nsDiffuse + (b - m)
    tickMs := tickMs.push ((b - a).toFloat / 1e6)
    if c.hashEvery != 0 && (t + 1) % c.hashEvery == 0 then
      stderr.putStrLn s!"tick {t + 1} grid={hex8 s.hashGrid} agents={hex8 s.hashAgents}"
  let t1 ← IO.monoNanosNow
  let msTotal := (t1 - t0).toFloat / 1e6

  let gh := s.hashGrid
  let ah := s.hashAgents
  let (mean, median, p99) := stats tickMs
  let n := tickMs.size

  if o.json then
    let maups := if msTotal > 0.0 then c.agents.toFloat * n.toFloat / msTotal / 1000.0 else 0.0
    let cells := (c.width * c.height).toFloat
    let mcups := if msTotal > 0.0 then cells * n.toFloat / msTotal / 1000.0 else 0.0
    let upd := match c.update with | Update.serial => "serial" | Update.deferred => "deferred"
    IO.println <| String.intercalate "" [
      "{\"schema\":1,\"impl\":\"lean\",\"backend\":\"headless\",\"class\":\"S\",",
      s!"\"preset\":\"{c.preset}\",\"variant\":\"scalar\",",
      s!"\"width\":{c.width},\"height\":{c.height},\"agents\":{c.agents},",
      s!"\"ticks\":{n},\"seed\":{c.seed.toNat},\"update\":\"{upd}\",\"threads\":1,",
      s!"\"grid_hash\":\"{hex8 gh}\",\"agent_hash\":\"{hex8 ah}\",",
      s!"\"dirtable_hash\":\"{hex8 dirtableHash}\",",
      s!"\"ms_total\":{msTotal},\"ms_agents\":{nsAgents.toFloat / 1e6},\"ms_diffuse\":{nsDiffuse.toFloat / 1e6},",
      s!"\"ms_per_tick_mean\":{mean},\"ms_per_tick_median\":{median},",
      s!"\"ms_per_tick_p99\":{p99},",
      s!"\"maups\":{maups},\"mcups\":{mcups}}"
    ]
  else
    let upd := match c.update with | Update.serial => "serial" | Update.deferred => "deferred"
    IO.println s!"{c.preset} {c.width}x{c.height} agents={c.agents} ticks={n} update={upd}"
    IO.println s!"  grid_hash  {hex8 gh}"
    IO.println s!"  agent_hash {hex8 ah}"
    IO.println s!"  total      {msTotal} ms  ({msTotal / (max n 1).toFloat} ms/tick)"
    IO.println s!"  agents     {nsAgents.toFloat / 1e6} ms"
    IO.println s!"  diffuse    {nsDiffuse.toFloat / 1e6} ms"
  return 0
