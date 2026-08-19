// slimebench -- Swift headless benchmark (classes S and P).

import Foundation
import SlimebenchCore

let usage = """
usage: slimebench [options]   (slimebench SPEC-1)
  --preset NAME        tiny|small|medium|large|huge|browser
  --width N --height N powers of two
  --agents N  --ticks N  --warmup N  --seed N
  --update MODE        serial|deferred
  --threads N
  --deposit-reduce M   private|binned  (SPEC-1 5.6)
  --sensor-dist F  --sensor-steps N  --rot-steps N
  --step F  --deposit F  --decay F
  --headless  --json  --hash-every N
  -h, --help
"""

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write("error: \(msg)\n\(usage)\n".data(using: .utf8)!)
    exit(2)
}

func preset(_ n: String) -> (UInt32, UInt32, UInt32, UInt32)? {
    switch n {
    case "tiny":    return (512, 512, 65_536, 1000)
    case "small":   return (1024, 1024, 262_144, 1000)
    case "medium":  return (2048, 2048, 1_048_576, 1000)
    case "large":   return (4096, 4096, 4_194_304, 500)
    case "huge":    return (8192, 8192, 16_777_216, 100)
    case "browser": return (1024, 1024, 262_144, 0)
    default:        return nil
    }
}

var cfg = Config()
var wantJSON = false

var argv = Array(CommandLine.arguments.dropFirst())
var i = 0
func need(_ flag: String) -> String {
    i += 1
    if i >= argv.count { fail("\(flag) requires a value") }
    return argv[i]
}
// `?? fail(...)` does not typecheck: Swift will not coerce Never into the
// operand type here, so the guard is spelled out.
func u32(_ s: String) -> UInt32 {
    guard let v = UInt32(s) else { fail("'\(s)' is not an integer") }
    return v
}
func f32(_ s: String) -> Float {
    guard let v = Float(s) else { fail("'\(s)' is not a number") }
    return v
}

while i < argv.count {
    let a = argv[i]
    switch a {
    case "-h", "--help": print(usage); exit(0)
    case "--json": wantJSON = true
    case "--headless", "--no-simd": break
    case "--simd": fail("this target has no vectorised kernel")
    case "--preset":
        let n = need(a)
        guard let p = preset(n) else { fail("unknown preset '\(n)'") }
        (cfg.width, cfg.height, cfg.agents, cfg.ticks) = p
        cfg.preset = n
    case "--width":  cfg.width = u32(need(a));  cfg.preset = "custom"
    case "--height": cfg.height = u32(need(a)); cfg.preset = "custom"
    case "--agents": cfg.agents = u32(need(a)); cfg.preset = "custom"
    case "--ticks":  cfg.ticks = u32(need(a))
    case "--warmup": cfg.warmup = u32(need(a))
    case "--seed":   cfg.seed = u32(need(a))
    case "--threads": cfg.threads = u32(need(a))
    case "--hash-every": cfg.hashEvery = u32(need(a))
    case "--sensor-steps": cfg.sensorSteps = u32(need(a))
    case "--rot-steps": cfg.rotSteps = u32(need(a))
    case "--sensor-dist": cfg.sensorDist = f32(need(a))
    case "--step": cfg.step = f32(need(a))
    case "--deposit": cfg.deposit = f32(need(a))
    case "--decay": cfg.decay = f32(need(a))
    case "--display-max", "--dump-grid": _ = need(a)
    case "--update":
        let m = need(a)
        guard let u = Update(rawValue: m) else { fail("--update must be serial|deferred") }
        cfg.update = u
    case "--deposit-reduce":
        let m = need(a)
        guard let r = Reduce(rawValue: m) else { fail("--deposit-reduce must be private|binned") }
        cfg.reduce = r
    default:
        // SPEC-1 section 10: never silently ignore an unknown flag.
        fail("unknown argument '\(a)'")
    }
    i += 1
}

let sim: Sim
do {
    sim = try Sim(cfg)
} catch {
    FileHandle.standardError.write("error: \(error)\n".data(using: .utf8)!)
    exit(1)
}

var msTotal = 0.0
var tickMs: [Double] = []
var cls = "S"

if cfg.threads > 1 {
    cls = "P"
    do {
        let r = try runParallel(sim, warmup: cfg.warmup, ticks: cfg.ticks)
        msTotal = r.msTotal
        tickMs = r.tickMs
    } catch {
        FileHandle.standardError.write("error: \(error)\n".data(using: .utf8)!)
        exit(2)
    }
} else {
    for _ in 0..<cfg.warmup { sim.tick() }
    sim.nsAgents = 0
    sim.nsDiffuse = 0

    tickMs.reserveCapacity(Int(cfg.ticks))
    let start = DispatchTime.now().uptimeNanoseconds
    for t in 0..<cfg.ticks {
        let a = DispatchTime.now().uptimeNanoseconds
        sim.tick()
        tickMs.append(Double(DispatchTime.now().uptimeNanoseconds - a) / 1e6)
        if cfg.hashEvery != 0 && (t + 1) % cfg.hashEvery == 0 {
            let s = String(format: "tick %d grid=0x%08X agents=0x%08X\n",
                           t + 1, sim.hashGrid(), sim.hashAgents())
            FileHandle.standardError.write(s.data(using: .utf8)!)
        }
    }
    msTotal = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
}

let variant = cfg.threads > 1 ? cfg.reduce.rawValue : "scalar"

if wantJSON {
    let n = tickMs.count
    let sorted = tickMs.sorted()
    let median = n > 0 ? sorted[n / 2] : 0
    let p99 = n > 0 ? sorted[min(n - 1, Int(Double(n) * 0.99))] : 0
    let mean = n > 0 ? tickMs.reduce(0, +) / Double(n) : 0
    let cells = Double(cfg.width) * Double(cfg.height)
    let maups = msTotal > 0 ? Double(cfg.agents) * Double(n) / msTotal / 1000 : 0
    let mcups = msTotal > 0 ? cells * Double(n) / msTotal / 1000 : 0

    var out = "{\"schema\":1,\"impl\":\"swift\",\"backend\":\"headless\",\"class\":\"\(cls)\","
    out += "\"preset\":\"\(cfg.preset)\",\"variant\":\"\(variant)\","
    out += "\"width\":\(cfg.width),\"height\":\(cfg.height),\"agents\":\(cfg.agents),"
    out += "\"ticks\":\(n),\"seed\":\(cfg.seed),\"update\":\"\(cfg.update.rawValue)\","
    out += "\"threads\":\(cfg.threads),"
    out += String(format: "\"grid_hash\":\"0x%08X\",\"agent_hash\":\"0x%08X\",\"dirtable_hash\":\"0x%08X\",",
                  sim.hashGrid(), sim.hashAgents(), dirtableHashRuntime())
    out += String(format: "\"ms_total\":%.4f,\"ms_agents\":%.4f,\"ms_diffuse\":%.4f,",
                  msTotal, Double(sim.nsAgents) / 1e6, Double(sim.nsDiffuse) / 1e6)
    out += String(format: "\"ms_per_tick_mean\":%.6f,\"ms_per_tick_median\":%.6f,\"ms_per_tick_p99\":%.6f,",
                  mean, median, p99)
    out += String(format: "\"maups\":%.4f,\"mcups\":%.4f}", maups, mcups)
    print(out)
} else {
    var head = "\(cfg.preset) \(cfg.width)x\(cfg.height) agents=\(cfg.agents)"
    head += " ticks=\(cfg.ticks) update=\(cfg.update.rawValue)"
    if cfg.threads > 1 { head += " threads=\(cfg.threads) reduce=\(cfg.reduce.rawValue)" }
    print(head)
    print(String(format: "  grid_hash  0x%08X", sim.hashGrid()))
    print(String(format: "  agent_hash 0x%08X", sim.hashAgents()))
    let per = cfg.ticks > 0 ? msTotal / Double(cfg.ticks) : 0
    print(String(format: "  total      %.2f ms  (%.4f ms/tick)", msTotal, per))
    print(String(format: "  agents     %.2f ms", Double(sim.nsAgents) / 1e6))
    print(String(format: "  diffuse    %.2f ms", Double(sim.nsDiffuse) / 1e6))
}
