(* slimebench -- OCaml implementation of SPEC-1.

   This port is the mirror image of impl/lean, and that is why it exists.

   Lean has a native [Float32] -- IEEE binary32, verified in docs/RESULTS.md
   section 2 -- but [Array Float32] stores every element as a heap object, so
   the data is boxed and the arithmetic is exact.

   OCaml 4.14 is the other way round on both counts. A [float array] is stored
   flat and unboxed (the runtime gives it [double_array_tag]), which is the
   representation Lean cannot express. But there is no float32 type at all:
   every [float] is IEEE binary64, and the only way to reach conformance tier A
   is to round each intermediate explicitly through
   [Int32.float_of_bits (Int32.bits_of_float x)].

   So the two ML-family ports pay opposite tolls, and the numbers say which
   toll is worse on this workload.

   The rounding is not free, and this build cannot hide it: the installed
   compiler has no flambda (checked with [ocamlopt -config]), so the [int32]
   the round-trip produces is a real allocation unless the non-flambda
   unboxing rules happen to apply. Pricing that is the point of the [f64]
   profile, which skips the rounding and is conformance tier B.

   OCaml 5.4 introduced a [Float32] module. If this ever runs on one, the
   right experiment is to add a third profile using it and find out whether
   native f32 beats a rounded f64 -- see the open questions in RESULTS. *)

let spec_version = "SPEC-1"

let fnv_offset = 0x811C9DC5
let fnv_prime = 0x01000193
let mask32 = 0xFFFFFFFF

(* [f32 x] rounds a float to the nearest binary32 value.

   [Int32.bits_of_float] is documented as returning the IEEE 754 *single
   format* representation, so it performs the f64 -> f32 rounding, and
   [float_of_bits] widens back without loss. This is the same trick
   slimebench_pure.py plays with struct.pack, in a language where it is a
   two-instruction conversion rather than a C call. *)
let[@inline] f32 (x : float) : float = Int32.float_of_bits (Int32.bits_of_float x)

(* ---- configuration ------------------------------------------------------ *)

type update = Serial | Deferred

let string_of_update = function Serial -> "serial" | Deferred -> "deferred"

type config = {
  mutable width : int;
  mutable height : int;
  mutable agents : int;
  mutable ticks : int;
  mutable warmup : int;
  mutable seed : int;
  mutable threads : int;
  mutable update : update;
  mutable sensor_dist : float;
  mutable step : float;
  mutable deposit : float;
  mutable decay : float;
  mutable sensor_steps : int;
  mutable rot_steps : int;
  mutable hash_every : int;
  mutable preset : string;
  mutable strict : bool;
}

let default_config () = {
  width = 1024; height = 1024; agents = 262144;
  ticks = 1000; warmup = 0; seed = 12345; threads = 1;
  update = Serial;
  sensor_dist = 9.0; step = 1.0; deposit = 10.0; decay = 0.94;
  sensor_steps = 144; rot_steps = 144;
  hash_every = 0; preset = "custom"; strict = true;
}

(* Every f32 parameter is rounded once at startup. 0.94 is the one that bites:
   the f64 literal and C's 0.94f are different numbers, and multiplying the
   whole grid by the wrong one every tick drifts the ports apart. 9.0, 1.0 and
   10.0 are exact in f32 either way. *)
let normalize_f32 c =
  c.sensor_dist <- f32 c.sensor_dist;
  c.step <- f32 c.step;
  c.deposit <- f32 c.deposit;
  c.decay <- f32 c.decay

(* ---- PRNG (SPEC-1 section 3.1) ------------------------------------------ *)
(* OCaml's [int] is 63 bits on a 64-bit host, so the 32-bit words fit with room
   for the multiplications: the widest intermediate is 0x735A2D97 * 0xFFFFFFFF,
   about 2^63 * 0.9, which is why each step masks immediately. *)

let[@inline] splitmix32 state =
  let state = (state + 0x9E3779B9) land mask32 in
  let z = state in
  let z = ((z lxor (z lsr 16)) * 0x21F0AAAD) land mask32 in
  let z = ((z lxor (z lsr 15)) * 0x735A2D97) land mask32 in
  (state, (z lxor (z lsr 15)) land mask32)

let[@inline] rotl32 x k = ((x lsl k) lor (x lsr (32 - k))) land mask32

(* Advances the four words at s.(o..o+3) and returns one draw. *)
let xoshiro128pp (s : int array) o =
  let s0 = s.(o) and s1 = s.(o + 1) and s2 = s.(o + 2) and s3 = s.(o + 3) in
  let result = (rotl32 ((s0 + s3) land mask32) 7 + s0) land mask32 in
  let t = (s1 lsl 9) land mask32 in
  let s2 = s2 lxor s0 in
  let s3 = s3 lxor s1 in
  let s1 = s1 lxor s2 in
  let s0 = s0 lxor s3 in
  let s2 = s2 lxor t in
  let s3 = rotl32 s3 11 in
  s.(o) <- s0; s.(o + 1) <- s1; s.(o + 2) <- s2; s.(o + 3) <- s3;
  result

(* Exact: u lsr 8 is below 2^24 and 16777216 is a power of two (SPEC-1 3.2). *)
let[@inline] rnd01 u = float_of_int (u lsr 8) /. 16777216.0

(* ---- simulation --------------------------------------------------------- *)

type t = {
  cfg : config;
  log2w : int;
  xmask : int;
  ymask : int;
  mutable grid : float array;
  mutable scratch : float array;
  dep : float array;          (* length 0 when update = Serial *)
  ax : float array;
  ay : float array;
  adir : int array;
  arng : int array;
  cos_t : float array;
  sin_t : float array;
  mutable ns_agents : int;
  mutable ns_diffuse : int;
}

let log2u v =
  let rec go n = if 1 lsl n >= v then n else go (n + 1) in
  go 0

let create cfg =
  if cfg.width <= 0 || cfg.width land (cfg.width - 1) <> 0 then
    failwith "width must be a power of two";
  if cfg.height <= 0 || cfg.height land (cfg.height - 1) <> 0 then
    failwith "height must be a power of two";
  normalize_f32 cfg;
  let cells = cfg.width * cfg.height in
  let s = {
    cfg;
    log2w = log2u cfg.width;
    xmask = cfg.width - 1;
    ymask = cfg.height - 1;
    grid = Array.make cells 0.0;
    scratch = Array.make cells 0.0;
    dep = (if cfg.update = Deferred then Array.make cells 0.0 else [||]);
    ax = Array.make cfg.agents 0.0;
    ay = Array.make cfg.agents 0.0;
    adir = Array.make cfg.agents 0;
    arng = Array.make (cfg.agents * 4) 0;
    cos_t = Array.map (fun b -> Int32.float_of_bits (Int32.of_int b)) Dirtable.cos_bits;
    sin_t = Array.map (fun b -> Int32.float_of_bits (Int32.of_int b)) Dirtable.sin_bits;
    ns_agents = 0;
    ns_diffuse = 0;
  } in
  (* SPEC-1 section 3.3. The products are computed in f64 and rounded once,
     which is what C does too: rnd01 is exact and 100.0 is a 7-bit integer, so
     the product needs 31 bits of mantissa and f64 holds it exactly. *)
  let sm = ref (cfg.seed lxor 0x5BF03635) in
  for i = 0 to cells - 1 do
    let st, u = splitmix32 !sm in
    sm := st;
    s.grid.(i) <- f32 (rnd01 u *. 100.0)
  done;
  let fw = float_of_int cfg.width and fh = float_of_int cfg.height in
  for i = 0 to cfg.agents - 1 do
    let sa = ref ((cfg.seed + (0x9E3779B9 * (i + 1))) land mask32) in
    let o = i * 4 in
    for k = 0 to 3 do
      let st, u = splitmix32 !sa in
      sa := st;
      s.arng.(o + k) <- u
    done;
    if s.arng.(o) lor s.arng.(o+1) lor s.arng.(o+2) lor s.arng.(o+3) = 0 then
      s.arng.(o) <- 1;
    s.ax.(i) <- f32 (rnd01 (xoshiro128pp s.arng o) *. fw);
    s.ay.(i) <- f32 (rnd01 (xoshiro128pp s.arng o) *. fh);
    s.adir.(i) <- xoshiro128pp s.arng o mod Dirtable.ndir
  done;
  s

(* ---- the passes ----------------------------------------------------------

   The two hot loops are written twice, once rounding every intermediate to f32
   and once not. That is deliberate and it is the only duplication in this
   file.

   The obvious alternative is to pass the rounding in as a function argument.
   It does not work here: this compiler has no flambda, so a [float -> float]
   parameter is an indirect call that cannot be inlined, and there are thirteen
   of them per agent and ten per cell. The tier-A version would then be
   measuring OCaml's closure-call overhead rather than the f32 round-trip, and
   the tier-B version -- which needs no rounding at all -- would be charged for
   it too. Two copies price the thing named on the label.

   There are also no [ref] cells in either loop. A [ref] that a closure
   captures escapes and is heap-allocated, which at one allocation per agent
   per tick is not a rounding error; shadowing [let] bindings compile to
   registers. *)

let agent_pass_strict s =
  let c = s.cfg in
  let grid = s.grid in
  let target = if c.update = Deferred then s.dep else s.grid in
  let ax = s.ax and ay = s.ay and adir = s.adir and rng = s.arng in
  let cos_t = s.cos_t and sin_t = s.sin_t in
  let xmask = s.xmask and ymask = s.ymask and log2w = s.log2w in
  let fw = float_of_int c.width and fh = float_of_int c.height in
  let sdist = c.sensor_dist and step = c.step and deposit = c.deposit in
  let ss = c.sensor_steps and rs = c.rot_steps in
  let nd = Dirtable.ndir in
  for i = 0 to c.agents - 1 do
    let d0 = adir.(i) in
    let x0 = ax.(i) and y0 = ay.(i) in
    let dl = (d0 - ss + nd) mod nd in
    let dr = (d0 + ss) mod nd in

    (* Each sensor read is written out. The order of the two wraps is
       normative and a helper would hide it. *)
    let sx = f32 (x0 +. f32 (cos_t.(dl) *. sdist)) in
    let sx = if sx < 0.0 then f32 (sx +. fw) else sx in
    let sx = if sx >= fw then f32 (sx -. fw) else sx in
    let sy = f32 (y0 +. f32 (sin_t.(dl) *. sdist)) in
    let sy = if sy < 0.0 then f32 (sy +. fh) else sy in
    let sy = if sy >= fh then f32 (sy -. fh) else sy in
    let fl = grid.(((int_of_float sy land ymask) lsl log2w)
                   lor (int_of_float sx land xmask)) in

    let sx = f32 (x0 +. f32 (cos_t.(d0) *. sdist)) in
    let sx = if sx < 0.0 then f32 (sx +. fw) else sx in
    let sx = if sx >= fw then f32 (sx -. fw) else sx in
    let sy = f32 (y0 +. f32 (sin_t.(d0) *. sdist)) in
    let sy = if sy < 0.0 then f32 (sy +. fh) else sy in
    let sy = if sy >= fh then f32 (sy -. fh) else sy in
    let fc = grid.(((int_of_float sy land ymask) lsl log2w)
                   lor (int_of_float sx land xmask)) in

    let sx = f32 (x0 +. f32 (cos_t.(dr) *. sdist)) in
    let sx = if sx < 0.0 then f32 (sx +. fw) else sx in
    let sx = if sx >= fw then f32 (sx -. fw) else sx in
    let sy = f32 (y0 +. f32 (sin_t.(dr) *. sdist)) in
    let sy = if sy < 0.0 then f32 (sy +. fh) else sy in
    let sy = if sy >= fh then f32 (sy -. fh) else sy in
    let fr = grid.(((int_of_float sy land ymask) lsl log2w)
                   lor (int_of_float sx land xmask)) in

    let d =
      if fc >= fl && fc >= fr then d0
      else if fc < fl && fc < fr then
        (* Only the dead-end case draws from the stream (SPEC-1 5.3). *)
        (if xoshiro128pp rng (i * 4) land 1 <> 0 then (d0 + rs) mod nd
         else (d0 - rs + nd) mod nd)
      else if fl > fr then (d0 - rs + nd) mod nd
      else (d0 + rs) mod nd
    in

    let x = f32 (x0 +. f32 (cos_t.(d) *. step)) in
    let x = if x < 0.0 then f32 (x +. fw) else x in
    let x = if x >= fw then f32 (x -. fw) else x in
    let y = f32 (y0 +. f32 (sin_t.(d) *. step)) in
    let y = if y < 0.0 then f32 (y +. fh) else y in
    let y = if y >= fh then f32 (y -. fh) else y in

    let idx = ((int_of_float y land ymask) lsl log2w)
              lor (int_of_float x land xmask) in
    target.(idx) <- f32 (target.(idx) +. deposit);
    adir.(i) <- d;
    ax.(i) <- x;
    ay.(i) <- y
  done

let agent_pass_f64 s =
  let c = s.cfg in
  let grid = s.grid in
  let target = if c.update = Deferred then s.dep else s.grid in
  let ax = s.ax and ay = s.ay and adir = s.adir and rng = s.arng in
  let cos_t = s.cos_t and sin_t = s.sin_t in
  let xmask = s.xmask and ymask = s.ymask and log2w = s.log2w in
  let fw = float_of_int c.width and fh = float_of_int c.height in
  let sdist = c.sensor_dist and step = c.step and deposit = c.deposit in
  let ss = c.sensor_steps and rs = c.rot_steps in
  let nd = Dirtable.ndir in
  for i = 0 to c.agents - 1 do
    let d0 = adir.(i) in
    let x0 = ax.(i) and y0 = ay.(i) in
    let dl = (d0 - ss + nd) mod nd in
    let dr = (d0 + ss) mod nd in

    let sx = x0 +. cos_t.(dl) *. sdist in
    let sx = if sx < 0.0 then sx +. fw else sx in
    let sx = if sx >= fw then sx -. fw else sx in
    let sy = y0 +. sin_t.(dl) *. sdist in
    let sy = if sy < 0.0 then sy +. fh else sy in
    let sy = if sy >= fh then sy -. fh else sy in
    let fl = grid.(((int_of_float sy land ymask) lsl log2w)
                   lor (int_of_float sx land xmask)) in

    let sx = x0 +. cos_t.(d0) *. sdist in
    let sx = if sx < 0.0 then sx +. fw else sx in
    let sx = if sx >= fw then sx -. fw else sx in
    let sy = y0 +. sin_t.(d0) *. sdist in
    let sy = if sy < 0.0 then sy +. fh else sy in
    let sy = if sy >= fh then sy -. fh else sy in
    let fc = grid.(((int_of_float sy land ymask) lsl log2w)
                   lor (int_of_float sx land xmask)) in

    let sx = x0 +. cos_t.(dr) *. sdist in
    let sx = if sx < 0.0 then sx +. fw else sx in
    let sx = if sx >= fw then sx -. fw else sx in
    let sy = y0 +. sin_t.(dr) *. sdist in
    let sy = if sy < 0.0 then sy +. fh else sy in
    let sy = if sy >= fh then sy -. fh else sy in
    let fr = grid.(((int_of_float sy land ymask) lsl log2w)
                   lor (int_of_float sx land xmask)) in

    let d =
      if fc >= fl && fc >= fr then d0
      else if fc < fl && fc < fr then
        (if xoshiro128pp rng (i * 4) land 1 <> 0 then (d0 + rs) mod nd
         else (d0 - rs + nd) mod nd)
      else if fl > fr then (d0 - rs + nd) mod nd
      else (d0 + rs) mod nd
    in

    let x = x0 +. cos_t.(d) *. step in
    let x = if x < 0.0 then x +. fw else x in
    let x = if x >= fw then x -. fw else x in
    let y = y0 +. sin_t.(d) *. step in
    let y = if y < 0.0 then y +. fh else y in
    let y = if y >= fh then y -. fh else y in

    let idx = ((int_of_float y land ymask) lsl log2w)
              lor (int_of_float x land xmask) in
    target.(idx) <- target.(idx) +. deposit;
    adir.(i) <- d;
    ax.(i) <- x;
    ay.(i) <- y
  done

let merge_dep s =
  if s.cfg.update = Deferred then begin
    let g = s.grid and d = s.dep in
    if s.cfg.strict then
      for i = 0 to Array.length g - 1 do
        g.(i) <- f32 (g.(i) +. d.(i)); d.(i) <- 0.0
      done
    else
      for i = 0 to Array.length g - 1 do
        g.(i) <- g.(i) +. d.(i); d.(i) <- 0.0
      done
  end

(* SPEC-1 section 5.4. The summation order is normative -- do not reorder. *)
let diffuse_pass_strict s =
  let c = s.cfg in
  let w = c.width and h = c.height in
  let log2w = s.log2w and xmask = s.xmask and ymask = s.ymask in
  let decay = c.decay in
  let src = s.grid and dst = s.scratch in
  for y = 0 to h - 1 do
    let rowm = ((y - 1) land ymask) lsl log2w in
    let row0 = y lsl log2w in
    let rowp = ((y + 1) land ymask) lsl log2w in
    for x = 0 to w - 1 do
      let xm = (x - 1) land xmask in
      let xp = (x + 1) land xmask in
      let acc = src.(rowm lor xm) in
      let acc = f32 (acc +. src.(rowm lor x)) in
      let acc = f32 (acc +. src.(rowm lor xp)) in
      let acc = f32 (acc +. src.(row0 lor xm)) in
      let acc = f32 (acc +. f32 (4.0 *. src.(row0 lor x))) in
      let acc = f32 (acc +. src.(row0 lor xp)) in
      let acc = f32 (acc +. src.(rowp lor xm)) in
      let acc = f32 (acc +. src.(rowp lor x)) in
      let acc = f32 (acc +. src.(rowp lor xp)) in
      dst.(row0 lor x) <- f32 (f32 (acc /. 12.0) *. decay)
    done
  done;
  s.grid <- dst;
  s.scratch <- src

let diffuse_pass_f64 s =
  let c = s.cfg in
  let w = c.width and h = c.height in
  let log2w = s.log2w and xmask = s.xmask and ymask = s.ymask in
  let decay = c.decay in
  let src = s.grid and dst = s.scratch in
  for y = 0 to h - 1 do
    let rowm = ((y - 1) land ymask) lsl log2w in
    let row0 = y lsl log2w in
    let rowp = ((y + 1) land ymask) lsl log2w in
    for x = 0 to w - 1 do
      let xm = (x - 1) land xmask in
      let xp = (x + 1) land xmask in
      let acc = src.(rowm lor xm) in
      let acc = acc +. src.(rowm lor x) in
      let acc = acc +. src.(rowm lor xp) in
      let acc = acc +. src.(row0 lor xm) in
      let acc = acc +. 4.0 *. src.(row0 lor x) in
      let acc = acc +. src.(row0 lor xp) in
      let acc = acc +. src.(rowp lor xm) in
      let acc = acc +. src.(rowp lor x) in
      let acc = acc +. src.(rowp lor xp) in
      dst.(row0 lor x) <- acc /. 12.0 *. decay
    done
  done;
  s.grid <- dst;
  s.scratch <- src

let tick s =
  let t0 = Unix.gettimeofday () in
  if s.cfg.strict then agent_pass_strict s else agent_pass_f64 s;
  let t1 = Unix.gettimeofday () in
  merge_dep s;
  if s.cfg.strict then diffuse_pass_strict s else diffuse_pass_f64 s;
  let t2 = Unix.gettimeofday () in
  s.ns_agents <- s.ns_agents + int_of_float ((t1 -. t0) *. 1e9);
  s.ns_diffuse <- s.ns_diffuse + int_of_float ((t2 -. t1) *. 1e9)

(* ---- checksums (SPEC-1 section 6) ---------------------------------------- *)

let[@inline] bits_u32 (x : float) =
  Int32.to_int (Int32.bits_of_float x) land mask32

let hash_grid s =
  let h = ref fnv_offset in
  Array.iter (fun v -> h := ((!h lxor bits_u32 v) * fnv_prime) land mask32) s.grid;
  !h

let hash_agents s =
  let h = ref fnv_offset in
  for i = 0 to s.cfg.agents - 1 do
    h := ((!h lxor bits_u32 s.ax.(i)) * fnv_prime) land mask32;
    h := ((!h lxor bits_u32 s.ay.(i)) * fnv_prime) land mask32;
    h := ((!h lxor s.adir.(i)) * fnv_prime) land mask32
  done;
  !h

let dirtable_hash () =
  let h = ref fnv_offset in
  let step b = h := ((!h lxor b) * fnv_prime) land mask32 in
  Array.iter step Dirtable.cos_bits;
  Array.iter step Dirtable.sin_bits;
  !h
