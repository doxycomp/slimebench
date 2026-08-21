(* slimebench -- OCaml headless benchmark (class S). *)

let usage = {|usage: slimebench [options]   (slimebench SPEC-1)
  --preset NAME        tiny|small|medium|large|huge|browser
  --width N --height N powers of two
  --agents N  --ticks N  --warmup N  --seed N
  --update MODE        serial|deferred
  --sensor-dist F  --sensor-steps N  --rot-steps N
  --step F  --deposit F  --decay F
  --headless  --json  --hash-every N
  --f64-intermediates  skip the f32 rounding -- conformance tier B
  -h, --help|}

let fail msg =
  prerr_endline ("error: " ^ msg);
  prerr_endline usage;
  exit 2

let apply_preset (c : Sim.config) name =
  let set w h a t = c.width <- w; c.height <- h; c.agents <- a; c.ticks <- t; true in
  let ok = match name with
    | "tiny"    -> set 512 512 65536 1000
    | "small"   -> set 1024 1024 262144 1000
    | "medium"  -> set 2048 2048 1048576 1000
    | "large"   -> set 4096 4096 4194304 500
    | "huge"    -> set 8192 8192 16777216 100
    | "browser" -> set 1024 1024 262144 0
    | _ -> false
  in
  if ok then c.preset <- name;
  ok

let int_arg name v =
  match int_of_string_opt v with
  | Some n -> n
  | None -> fail (Printf.sprintf "%s: '%s' is not an integer" name v)

let float_arg name v =
  match float_of_string_opt v with
  | Some f -> f
  | None -> fail (Printf.sprintf "%s: '%s' is not a number" name v)

let () =
  let c = Sim.default_config () in
  let want_json = ref false in
  let dump_grid = ref "" in
  let argv = Sys.argv in
  let n = Array.length argv in
  let i = ref 1 in
  while !i < n do
    let a = argv.(!i) in
    (* Every option except the bare flags takes exactly one value. *)
    let next () =
      if !i + 1 >= n then fail (a ^ " requires a value");
      incr i;
      argv.(!i)
    in
    (match a with
     | "-h" | "--help" -> print_endline usage; exit 0
     | "--json" -> want_json := true
     | "--headless" | "--no-simd" -> ()
     | "--simd" -> fail "this target has no vectorised kernel"
     | "--f64-intermediates" -> c.strict <- false
     | "--preset" ->
       let v = next () in
       if not (apply_preset c v) then fail ("unknown preset '" ^ v ^ "'")
     | "--width"  -> c.width <- int_arg a (next ()); c.preset <- "custom"
     | "--height" -> c.height <- int_arg a (next ()); c.preset <- "custom"
     | "--agents" -> c.agents <- int_arg a (next ()); c.preset <- "custom"
     | "--ticks"  -> c.ticks <- int_arg a (next ())
     | "--warmup" -> c.warmup <- int_arg a (next ())
     | "--seed"   -> c.seed <- int_arg a (next ())
     | "--threads" ->
       let t = int_arg a (next ()) in
       if t > 1 then fail "this target is class S only; --threads must be 1";
       c.threads <- t
     | "--hash-every"   -> c.hash_every <- int_arg a (next ())
     | "--sensor-steps" -> c.sensor_steps <- int_arg a (next ())
     | "--rot-steps"    -> c.rot_steps <- int_arg a (next ())
     | "--sensor-dist"  -> c.sensor_dist <- float_arg a (next ())
     | "--step"         -> c.step <- float_arg a (next ())
     | "--deposit"      -> c.deposit <- float_arg a (next ())
     | "--decay"        -> c.decay <- float_arg a (next ())
     (* The tolerant conformance gate reads this back: at tier B the hashes
        cannot match by construction, so run.py compares grid metrics instead
        and needs the grid itself. *)
     | "--dump-grid" -> dump_grid := next ()
     (* Accepted for CLI compatibility, unused by a headless target. *)
     | "--display-max" -> ignore (next ())
     | "--deposit-reduce" -> ignore (next ())
     | "--update" ->
       (match next () with
        | "serial" -> c.update <- Sim.Serial
        | "deferred" -> c.update <- Sim.Deferred
        | _ -> fail "--update must be serial|deferred")
     (* SPEC-1 section 10: never silently ignore an unknown flag. *)
     | _ -> fail ("unknown argument '" ^ a ^ "'"));
    incr i
  done;

  let s = try Sim.create c with Failure m -> fail m in

  for _ = 1 to c.warmup do Sim.tick s done;
  s.ns_agents <- 0;
  s.ns_diffuse <- 0;

  let tick_ms = Array.make (max c.ticks 0) 0.0 in
  let t_start = Unix.gettimeofday () in
  for t = 0 to c.ticks - 1 do
    let a = Unix.gettimeofday () in
    Sim.tick s;
    tick_ms.(t) <- (Unix.gettimeofday () -. a) *. 1000.0;
    if c.hash_every <> 0 && (t + 1) mod c.hash_every = 0 then
      Printf.eprintf "tick %d grid=0x%08X agents=0x%08X\n"
        (t + 1) (Sim.hash_grid s) (Sim.hash_agents s)
  done;
  let ms_total = (Unix.gettimeofday () -. t_start) *. 1000.0 in

  (* Raw little-endian f32, one word per cell -- the same bytes every other
     port writes, so one reader handles all of them. The values are rounded on
     the way out, which at tier B is where the f32 rounding finally happens. *)
  if !dump_grid <> "" then begin
    let oc = open_out_bin !dump_grid in
    let buf = Bytes.create 4 in
    Array.iter (fun v ->
      Bytes.set_int32_le buf 0 (Int32.bits_of_float v);
      output_bytes oc buf) s.Sim.grid;
    close_out oc
  end;

  (* What the collector did, under SLIMEBENCH_GC_STATS=1. quick_stat is the
     cheap one: it reads counters the runtime already maintains rather than
     walking the heap. *)
  (match Sys.getenv_opt "SLIMEBENCH_GC_STATS" with
   | Some "1" ->
     let g = Gc.quick_stat () in
     Printf.eprintf
       "gc_stats minor_words=%.0f minor_collections=%d major_collections=%d \
        heap_mib=%.1f ticks=%d\n"
       g.Gc.minor_words g.Gc.minor_collections g.Gc.major_collections
       (float_of_int (g.Gc.heap_words * (Sys.word_size / 8)) /. 1048576.0)
       c.ticks
   | _ -> ());

  let variant = if c.strict then "strict-f32" else "f64" in
  if !want_json then begin
    let k = Array.length tick_ms in
    let sorted = Array.copy tick_ms in
    Array.sort compare sorted;
    let median = if k > 0 then sorted.(k / 2) else 0.0 in
    let p99 = if k > 0 then sorted.(min (k - 1) (int_of_float (float_of_int k *. 0.99))) else 0.0 in
    let mean = if k > 0 then Array.fold_left ( +. ) 0.0 tick_ms /. float_of_int k else 0.0 in
    let cells = float_of_int c.width *. float_of_int c.height in
    let maups = if ms_total > 0.0 then float_of_int c.agents *. float_of_int k /. ms_total /. 1000.0 else 0.0 in
    let mcups = if ms_total > 0.0 then cells *. float_of_int k /. ms_total /. 1000.0 else 0.0 in
    Printf.printf
      "{\"schema\":1,\"impl\":\"ocaml\",\"backend\":\"headless\",\"class\":\"S\",\
       \"preset\":\"%s\",\"variant\":\"%s\",\"width\":%d,\"height\":%d,\
       \"agents\":%d,\"ticks\":%d,\"seed\":%d,\"update\":\"%s\",\"threads\":%d,\
       \"grid_hash\":\"0x%08X\",\"agent_hash\":\"0x%08X\",\"dirtable_hash\":\"0x%08X\",\
       \"ms_total\":%.4f,\"ms_agents\":%.4f,\"ms_diffuse\":%.4f,\
       \"ms_per_tick_mean\":%.6f,\"ms_per_tick_median\":%.6f,\"ms_per_tick_p99\":%.6f,\
       \"maups\":%.4f,\"mcups\":%.4f}\n"
      c.preset variant c.width c.height c.agents k c.seed
      (Sim.string_of_update c.update) c.threads
      (Sim.hash_grid s) (Sim.hash_agents s) (Sim.dirtable_hash ())
      ms_total
      (float_of_int s.ns_agents /. 1e6) (float_of_int s.ns_diffuse /. 1e6)
      mean median p99 maups mcups
  end else begin
    Printf.printf "%s %dx%d agents=%d ticks=%d update=%s variant=%s\n"
      c.preset c.width c.height c.agents c.ticks
      (Sim.string_of_update c.update) variant;
    Printf.printf "  grid_hash  0x%08X\n" (Sim.hash_grid s);
    Printf.printf "  agent_hash 0x%08X\n" (Sim.hash_agents s);
    Printf.printf "  total      %.2f ms  (%.4f ms/tick)\n"
      ms_total (if c.ticks > 0 then ms_total /. float_of_int c.ticks else 0.0);
    Printf.printf "  agents     %.2f ms\n" (float_of_int s.ns_agents /. 1e6);
    Printf.printf "  diffuse    %.2f ms\n" (float_of_int s.ns_diffuse /. 1e6)
  end
