// slimebench -- Swift implementation of SPEC-1.
//
// # Why this is conformance tier A without any flags
//
// Swift's `Float` is IEEE-754 binary32 and the language does not permit the
// optimiser to reassociate or to contract a multiply and an add: there is no
// `-ffast-math` equivalent that is on by default, and `Float` arithmetic is
// specified operation by operation. `0.94 as Float` is 0x3F70A3D7, the same
// bits C's `0.94f` produces -- checked, not assumed.
//
// So unlike C (which needs -ffp-contract=off) and Go (which needs an explicit
// conversion to forbid fusion), Swift needs nothing written differently. That
// is a real difference between the three and worth the sentence.
//
// # Where the unsafe is, and why
//
// `Array<Float>` subscripting is bounds-checked, and `-Ounchecked` removes
// those checks for the whole module -- but it also removes overflow traps on
// integer arithmetic, and this simulation relies on `&*` and `&+` wrapping
// deliberately in the PRNG. Rather than flip a whole-module switch whose
// second effect is silent, the hot loops take
// `UnsafeMutableBufferPointer` explicitly, and the safe variant simply does
// not. Both are built, and the harness reports them side by side, the same
// way the Rust target does.

import Foundation

public let SPEC_VERSION = "SPEC-1"

public let FNV_OFFSET: UInt32 = 0x811C_9DC5
public let FNV_PRIME: UInt32 = 0x0100_0193

public enum Update: String {
    case serial, deferred
}

/// SPEC-1 section 5.6.
public enum Reduce: String {
    case binned, `private`
}

public struct Config {
    public var width: UInt32 = 1024
    public var height: UInt32 = 1024
    public var agents: UInt32 = 262_144
    public var ticks: UInt32 = 1000
    public var warmup: UInt32 = 0
    public var seed: UInt32 = 12345
    public var threads: UInt32 = 1
    /// Ticks between spatial re-sorts of the agent arrays; 0 = never.
    /// See `agentSort` -- it changes which agent sits where, not what
    /// any of them computes.
    public var agentTile: UInt32 = 0
    public var update: Update = .serial
    public var reduce: Reduce = .binned
    public var sensorDist: Float = 9.0
    public var step: Float = 1.0
    public var deposit: Float = 10.0
    public var decay: Float = 0.94
    public var sensorSteps: UInt32 = 144
    public var rotSteps: UInt32 = 144
    public var hashEvery: UInt32 = 0
    public var preset: String = "custom"

    public init() {}
}

// ---- PRNG (SPEC-1 section 3.1) ---------------------------------------------
// `&+` and `&*` are the wrapping operators. Swift's plain `+` traps on
// overflow, which is the right default and exactly wrong for a PRNG.

@inline(__always)
public func splitmix32(_ state: inout UInt32) -> UInt32 {
    state = state &+ 0x9E37_79B9
    var z = state
    z = (z ^ (z >> 16)) &* 0x21F0_AAAD
    z = (z ^ (z >> 15)) &* 0x735A_2D97
    return z ^ (z >> 15)
}

@inline(__always)
func rotl32(_ x: UInt32, _ k: UInt32) -> UInt32 { (x << k) | (x >> (32 - k)) }

@inline(__always)
public func xoshiro128pp(_ s: UnsafeMutablePointer<UInt32>, _ o: Int) -> UInt32 {
    let result = rotl32(s[o] &+ s[o + 3], 7) &+ s[o]
    let t = s[o + 1] << 9
    s[o + 2] ^= s[o]
    s[o + 3] ^= s[o + 1]
    s[o + 1] ^= s[o + 2]
    s[o] ^= s[o + 3]
    s[o + 2] ^= t
    s[o + 3] = rotl32(s[o + 3], 11)
    return result
}

/// SPEC-1 section 3.2. Exact: `u >> 8 < 2^24`, and 2^24 is a power of two.
@inline(__always)
public func rnd01(_ u: UInt32) -> Float { Float(u >> 8) / 16_777_216.0 }

/// SPEC-1 section 2.2 -- a single conditional shift, not a modulo.
@inline(__always)
func wrapf(_ v0: Float, _ m: Float) -> Float {
    var v = v0
    if v < 0.0 { v += m }
    if v >= m { v -= m }
    return v
}

// ---- simulation -------------------------------------------------------------

public final class Sim {
    public let cfg: Config
    public let log2w: UInt32
    public let xmask: UInt32
    public let ymask: UInt32

    public var grid: [Float]
    public var scratch: [Float]
    public var dep: [Float]
    public var hasDep: Bool

    public var ax: [Float]
    public var ay: [Float]
    public var adir: [UInt16]
    public var arng: [UInt32]

    /// Spatial ordering (`Config.agentTile`). `aid[j]` is the original index
    /// of the agent now in slot j and `slot[a]` is its inverse; everything
    /// that has to speak in agent indices rather than slots -- the deposit,
    /// the agent hash -- goes through one of them. Empty when ordering is off.
    public var aid: [UInt32] = []
    public var slot: [UInt32] = []
    var agentIdx: [Int32] = []
    var sortKey: [UInt32] = []
    var sortF32: [Float] = []
    var sortU32: [UInt32] = []
    var sortU16: [UInt16] = []
    var ticksDone: UInt32 = 0

    let cosT: [Float]
    let sinT: [Float]

    public var nsAgents: Int = 0
    public var nsDiffuse: Int = 0

    public init(_ cfg: Config) throws {
        guard cfg.width > 0, cfg.width & (cfg.width - 1) == 0 else {
            throw SimError.notPowerOfTwo("width")
        }
        guard cfg.height > 0, cfg.height & (cfg.height - 1) == 0 else {
            throw SimError.notPowerOfTwo("height")
        }
        self.cfg = cfg
        self.log2w = UInt32(cfg.width.trailingZeroBitCount)
        self.xmask = cfg.width - 1
        self.ymask = cfg.height - 1

        let cells = Int(cfg.width) * Int(cfg.height)
        let n = Int(cfg.agents)
        grid = [Float](repeating: 0, count: cells)
        scratch = [Float](repeating: 0, count: cells)
        hasDep = cfg.update == .deferred
        dep = [Float](repeating: 0, count: hasDep ? cells : 0)
        ax = [Float](repeating: 0, count: n)
        ay = [Float](repeating: 0, count: n)
        adir = [UInt16](repeating: 0, count: n)
        arng = [UInt32](repeating: 0, count: n * 4)
        if cfg.agentTile > 0 {
            aid = (0..<UInt32(n)).map { $0 }
            slot = aid
            agentIdx = [Int32](repeating: 0, count: n)
            sortKey = [UInt32](repeating: 0, count: n)
            sortF32 = [Float](repeating: 0, count: n)
            sortU32 = [UInt32](repeating: 0, count: n * 4)
            sortU16 = [UInt16](repeating: 0, count: n)
        }
        cosT = COS_BITS.map { Float(bitPattern: $0) }
        sinT = SIN_BITS.map { Float(bitPattern: $0) }

        initState()
    }

    /// SPEC-1 section 3.3.
    private func initState() {
        var sm = cfg.seed ^ 0x5BF0_3635
        for i in 0..<grid.count {
            grid[i] = rnd01(splitmix32(&sm)) * 100.0
        }
        let fw = Float(cfg.width)
        let fh = Float(cfg.height)
        arng.withUnsafeMutableBufferPointer { rp in
            let r = rp.baseAddress!
            for i in 0..<Int(cfg.agents) {
                var sa = cfg.seed &+ 0x9E37_79B9 &* UInt32(i + 1)
                let o = i * 4
                r[o] = splitmix32(&sa)
                r[o + 1] = splitmix32(&sa)
                r[o + 2] = splitmix32(&sa)
                r[o + 3] = splitmix32(&sa)
                if r[o] | r[o + 1] | r[o + 2] | r[o + 3] == 0 { r[o] = 1 }
                ax[i] = rnd01(xoshiro128pp(r, o)) * fw
                ay[i] = rnd01(xoshiro128pp(r, o)) * fh
                adir[i] = UInt16(xoshiro128pp(r, o) % UInt32(NDIR))
            }
        }
    }

    /// SPEC-1 section 5.2.
    /// A counting sort of the agent arrays into 8x8 tiles of the grid, so
    /// that three sensor reads of neighbouring agents land in neighbouring
    /// cache lines. impl/c/sb_core.c carries the measurement behind the tile
    /// size; this is the same algorithm.
    func agentSort() {
        let tileShift: UInt32 = 3          // 8x8 cells
        let n = Int(cfg.agents)
        let tw = (cfg.width + (1 << tileShift) - 1) >> tileShift
        let th = (cfg.height + (1 << tileShift) - 1) >> tileShift

        var count = [UInt32](repeating: 0, count: Int(tw) * Int(th) + 1)
        for j in 0..<n {
            let x = UInt32(ax[j]) & xmask
            let y = UInt32(ay[j]) & ymask
            let k = (y >> tileShift) * tw + (x >> tileShift)
            sortKey[j] = k
            count[Int(k) + 1] += 1
        }
        for t in 1..<count.count { count[t] += count[t - 1] }

        // Stable: walking the agents in their current order keeps a re-sort
        // cheap when almost nothing has moved.
        for j in 0..<n {
            let k = Int(sortKey[j])
            let dst = Int(count[k])
            count[k] += 1
            sortF32[dst] = ax[j]
            sortU16[dst] = adir[j]
            for w in 0..<4 { sortU32[dst * 4 + w] = arng[j * 4 + w] }
            sortKey[j] = UInt32(dst)       // reused as the permutation
        }
        swap(&ax, &sortF32)
        swap(&adir, &sortU16)
        swap(&arng, &sortU32)
        for j in 0..<n { sortF32[Int(sortKey[j])] = ay[j] }
        swap(&ay, &sortF32)
        for j in 0..<n { sortU32[Int(sortKey[j])] = aid[j] }
        for j in 0..<n { aid[j] = sortU32[j] }
        for j in 0..<n { slot[Int(aid[j])] = UInt32(j) }
    }

    public func tick() {
        // Re-sort inside the timed region, not beside it: the ordering is only
        // worth having if it pays for itself.
        if cfg.agentTile > 0 && ticksDone % cfg.agentTile == 0 { agentSort() }
        ticksDone += 1

        let t0 = DispatchTime.now().uptimeNanoseconds
        if !aid.isEmpty {
            // With spatial ordering the step order is no longer the agent
            // order, so the deposits are buffered and applied afterwards in
            // ascending *agent* index -- the same order, and therefore the
            // same floats, as the direct loop.
            let n = Int(cfg.agents)
            agentIdx.withUnsafeMutableBufferPointer { buf in
                agentRange(0, n, buf.baseAddress)
            }
            let d = cfg.deposit
            for a in 0..<n {
                let idx = Int(agentIdx[Int(slot[a])])
                if hasDep { dep[idx] = dep[idx] + d } else { grid[idx] = grid[idx] + d }
            }
        } else {
            agentRange(0, Int(cfg.agents), nil)
        }
        let t1 = DispatchTime.now().uptimeNanoseconds

        if hasDep { mergeRows(0, Int(cfg.height)) }
        diffuseRows(0, Int(cfg.height))
        swapBuffers()

        let t2 = DispatchTime.now().uptimeNanoseconds
        nsAgents += Int(t1 - t0)
        nsDiffuse += Int(t2 - t1)
    }

    public func swapBuffers() { swap(&grid, &scratch) }

    /// Fold `dep` into `grid` over rows [y0, y1) and clear it.
    public func mergeRows(_ y0: Int, _ y1: Int) {
        guard hasDep else { return }
        let lo = y0 << log2w, hi = y1 << log2w
        grid.withUnsafeMutableBufferPointer { g in
            dep.withUnsafeMutableBufferPointer { d in
                for i in lo..<hi {
                    g[i] += d[i]
                    d[i] = 0.0
                }
            }
        }
    }

    /// SPEC-1 section 5.3 over agents [lo, hi).
    ///
    /// With `aidx` the deposit is not applied; the target cell is recorded for
    /// a later phase to apply in a chosen order. That is the only thing the
    /// threaded caller does differently -- everything above it has to stay
    /// identical, or the parallel run stops being the same simulation.
    public func agentRange(_ lo: Int, _ hi: Int, _ aidx: UnsafeMutablePointer<Int32>?) {
        let fw = Float(cfg.width), fh = Float(cfg.height)
        let sdist = cfg.sensorDist, step = cfg.step, deposit = cfg.deposit
        let ss = Int32(cfg.sensorSteps), rs = Int32(cfg.rotSteps)
        let nd = Int32(NDIR)
        let xm = xmask, ym = ymask, l2 = log2w

        grid.withUnsafeMutableBufferPointer { gp in
        dep.withUnsafeMutableBufferPointer { dp in
        ax.withUnsafeMutableBufferPointer { axp in
        ay.withUnsafeMutableBufferPointer { ayp in
        adir.withUnsafeMutableBufferPointer { adp in
        arng.withUnsafeMutableBufferPointer { rp in
        cosT.withUnsafeBufferPointer { cp in
        sinT.withUnsafeBufferPointer { sp in
            let g = gp.baseAddress!
            // In `serial` the deposit target is the grid itself.
            let target = self.hasDep ? dp.baseAddress! : g
            let r = rp.baseAddress!
            let cos = cp.baseAddress!, sin = sp.baseAddress!

            @inline(__always)
            func sense(_ x: Float, _ y: Float, _ d: Int32) -> Float {
                let sx = wrapf(x + cos[Int(d)] * sdist, fw)
                let sy = wrapf(y + sin[Int(d)] * sdist, fh)
                return g[Int(((UInt32(sy) & ym) << l2) | (UInt32(sx) & xm))]
            }

            for i in lo..<hi {
                var d = Int32(adp[i])
                var x = axp[i], y = ayp[i]

                let dl = (d - ss + nd) % nd
                let dr = (d + ss) % nd
                let fl = sense(x, y, dl)
                let fc = sense(x, y, d)
                let fr = sense(x, y, dr)

                if fc >= fl && fc >= fr {
                    // straight on
                } else if fc < fl && fc < fr {
                    // Only the dead-end case draws from the stream.
                    if xoshiro128pp(r, i * 4) & 1 != 0 {
                        d = (d + rs) % nd
                    } else {
                        d = (d - rs + nd) % nd
                    }
                } else if fl > fr {
                    d = (d - rs + nd) % nd
                } else {
                    d = (d + rs) % nd
                }

                x = wrapf(x + cos[Int(d)] * step, fw)
                y = wrapf(y + sin[Int(d)] * step, fh)

                let idx = Int(((UInt32(y) & ym) << l2) | (UInt32(x) & xm))
                if let a = aidx {
                    a[i] = Int32(idx)
                } else {
                    target[idx] += deposit
                }

                adp[i] = UInt16(d)
                axp[i] = x
                ayp[i] = y
            }
        }}}}}}}}
    }

    /// SPEC-1 section 5.4 over rows [y0, y1), writing into `scratch`.
    /// Summation order is normative -- do not reorder. Output cells are
    /// independent, so splitting the row range across threads is
    /// unconditionally bit-identical.
    public func diffuseRows(_ y0: Int, _ y1: Int) {
        let w = cfg.width, decay = cfg.decay
        let xm = xmask, ym = ymask, l2 = log2w

        grid.withUnsafeBufferPointer { sp in
        scratch.withUnsafeMutableBufferPointer { dp in
            let src = sp.baseAddress!, dst = dp.baseAddress!
            for y in UInt32(y0)..<UInt32(y1) {
                let rowm = ((y &- 1) & ym) << l2
                let row0 = y << l2
                let rowp = ((y &+ 1) & ym) << l2

                for x in UInt32(0)..<w {
                    let xmi = (x &- 1) & xm
                    let xpi = (x &+ 1) & xm

                    var acc = src[Int(rowm | xmi)]
                    acc = acc + src[Int(rowm | x)]
                    acc = acc + src[Int(rowm | xpi)]
                    acc = acc + src[Int(row0 | xmi)]
                    acc = acc + 4.0 * src[Int(row0 | x)]
                    acc = acc + src[Int(row0 | xpi)]
                    acc = acc + src[Int(rowp | xmi)]
                    acc = acc + src[Int(rowp | x)]
                    acc = acc + src[Int(rowp | xpi)]

                    dst[Int(row0 | x)] = (acc / 12.0) * decay
                }
            }
        }}
    }

    // ---- checksums (SPEC-1 section 6) ---------------------------------------

    public func hashGrid() -> UInt32 {
        var h = FNV_OFFSET
        for v in grid { h = (h ^ v.bitPattern) &* FNV_PRIME }
        return h
    }

    public func hashAgents() -> UInt32 {
        var h = FNV_OFFSET
        // In agent order, which is slot order only when the arrays have not
        // been spatially re-sorted. A checksum that changed with a performance
        // flag would defeat the point of having one.
        for a in 0..<Int(cfg.agents) {
            let i = slot.isEmpty ? a : Int(slot[a])
            h = (h ^ ax[i].bitPattern) &* FNV_PRIME
            h = (h ^ ay[i].bitPattern) &* FNV_PRIME
            h = (h ^ UInt32(adir[i])) &* FNV_PRIME
        }
        return h
    }

    /// SPEC-1 section 11, for the windowed frontends.
    public func renderGray(_ out: inout [UInt8], _ displayMax: Float) {
        let scale = 255.0 / displayMax
        for i in 0..<grid.count {
            let b = Int32(grid[i] * scale)
            out[i] = UInt8(b < 0 ? 0 : (b > 255 ? 255 : b))
        }
    }
}

public func dirtableHashRuntime() -> UInt32 {
    var h = FNV_OFFSET
    for b in COS_BITS { h = (h ^ b) &* FNV_PRIME }
    for b in SIN_BITS { h = (h ^ b) &* FNV_PRIME }
    return h
}

public enum SimError: Error, CustomStringConvertible {
    case notPowerOfTwo(String)
    case serialNotParallel

    public var description: String {
        switch self {
        case .notPowerOfTwo(let f): return "\(f) must be a power of two"
        case .serialNotParallel:
            return """
                --threads > 1 requires --update deferred.
                       SPEC-1 'serial' makes an agent's deposit visible to the
                       next agent in the same tick, which is a sequential
                       dependency; see SPEC-1 section 5.5.
                """
        }
    }
}
