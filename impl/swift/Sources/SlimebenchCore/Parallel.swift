// Multi-threaded tick (SPEC-1 section 5.6, benchmark class P).
//
// Both reduction strategies, the same phase order and the same deposit order
// as the C reference, so `binned` is bit-identical to the single-threaded run
// here too. The agent rule and the stencil are not reimplemented: this file
// calls Sim.agentRange and Sim.diffuseRows, the same code the serial path uses.
//
// # Threads, not Dispatch
//
// The obvious Swift answer is `DispatchQueue.concurrentPerform`, and it is the
// wrong one here: it is a fork-join over one phase, so a six-phase tick means
// six fork-joins per tick, each re-entering the thread pool. What this needs is
// six *barriers* between workers that stay alive for the whole run, which is
// `Foundation.Thread` plus a condition variable.
//
// Swift 6's strict concurrency does not model this -- the workers share one
// mutable grid and coordinate by barrier, which is exactly what the actor model
// is designed to prevent. `@unchecked Sendable` is the honest annotation: the
// safety argument is the barrier, and it is written out below rather than
// checked by the compiler.

import Foundation

final class Barrier {
    private let n: Int
    private let cond = NSCondition()
    private var count = 0
    private var sense = false

    init(_ n: Int) { self.n = n }

    func wait() {
        cond.lock()
        let my = !sense
        count += 1
        if count == n {
            count = 0
            sense = my
            cond.broadcast()
        } else {
            while sense != my { cond.wait() }
        }
        cond.unlock()
    }
}

/// Contiguous split of [0, n) into `parts`; part `i` is [lo, hi). Identical to
/// the C reference's `split`: the partition is what makes `binned` reproduce
/// the serial deposit order.
@inline(__always)
func splitRange(_ n: Int, _ parts: Int, _ i: Int) -> (Int, Int) {
    let base = n / parts, rem = n % parts
    let lo = i * base + Swift.min(i, rem)
    return (lo, lo + base + (i < rem ? 1 : 0))
}

/// Everything the workers share. Unchecked because the invariant that makes it
/// safe -- disjoint index ranges per phase, phases separated by barriers -- is
/// not one the compiler can see.
final class Pool: @unchecked Sendable {
    let sim: Sim
    let t: Int
    let cells: Int
    let agents: Int
    let height: Int
    let log2w: UInt32
    let deposit: Float
    let reduce: Reduce
    let adaptive: Bool
    let bar: Barrier

    var aidx: UnsafeMutablePointer<Int32>
    var sorted: UnsafeMutablePointer<Int32>
    var counts: UnsafeMutablePointer<Int32>
    var offsets: UnsafeMutablePointer<Int32>
    var ybucket: UnsafeMutablePointer<Int32>
    var rowcnt: UnsafeMutablePointer<Int32>
    var rowsum: UnsafeMutablePointer<Int32>
    var priv: UnsafeMutablePointer<Float>

    init(_ sim: Sim, adaptive: Bool) {
        self.sim = sim
        let c = sim.cfg
        t = Int(c.threads)
        cells = Int(c.width) * Int(c.height)
        agents = Int(c.agents)
        height = Int(c.height)
        log2w = sim.log2w
        deposit = c.deposit
        reduce = c.reduce
        self.adaptive = adaptive && c.reduce == .binned
        bar = Barrier(t)

        let binned = c.reduce == .binned
        func alloc32(_ n: Int) -> UnsafeMutablePointer<Int32> {
            let p = UnsafeMutablePointer<Int32>.allocate(capacity: Swift.max(1, n))
            p.initialize(repeating: 0, count: Swift.max(1, n))
            return p
        }
        aidx = alloc32(agents)
        sorted = alloc32(binned ? agents : 1)
        counts = alloc32(binned ? t * t : 1)
        offsets = alloc32(binned ? t * t : 1)
        ybucket = alloc32(binned ? height : 1)
        rowcnt = alloc32(binned && self.adaptive ? t * height : 1)
        rowsum = alloc32(binned && self.adaptive ? height : 1)
        let pn = binned ? 1 : t * cells
        priv = UnsafeMutablePointer<Float>.allocate(capacity: pn)
        priv.initialize(repeating: 0, count: pn)

        if binned {
            // Row -> owning worker, same split as the diffusion pass so a
            // worker's deposits land in rows it already touches.
            for b in 0..<t {
                let (lo, hi) = splitRange(height, t, b)
                for y in lo..<hi { ybucket[y] = Int32(b) }
            }
        }
    }

    deinit {
        aidx.deallocate(); sorted.deallocate(); counts.deallocate()
        offsets.deallocate(); ybucket.deallocate(); rowcnt.deallocate()
        rowsum.deallocate(); priv.deallocate()
    }

    @inline(__always)
    func bucketOf(_ idx: Int32) -> Int { Int(ybucket[Int(idx) >> log2w]) }

    // ---- private ----------------------------------------------------------

    func agentsPrivate(_ tid: Int) {
        let (lo, hi) = splitRange(agents, t, tid)
        sim.agentRange(lo, hi, aidx)
        let base = tid * cells
        for i in lo..<hi { priv[base + Int(aidx[i])] += deposit }
    }

    /// Fixed worker order, so the result is reproducible for this worker
    /// count. It is NOT in general the same grouping as the serial chain.
    func mergePrivate(_ tid: Int) {
        let (lo, hi) = splitRange(cells, t, tid)
        sim.grid.withUnsafeMutableBufferPointer { gp in
            let g = gp.baseAddress!
            for i in lo..<hi {
                var acc = priv[i]
                priv[i] = 0
                for k in 1..<t {
                    acc += priv[k * cells + i]
                    priv[k * cells + i] = 0
                }
                g[i] += acc
            }
        }
    }

    // ---- binned -----------------------------------------------------------

    func agentsBinned(_ tid: Int) {
        let (lo, hi) = splitRange(agents, t, tid)
        for b in 0..<t { counts[tid * t + b] = 0 }
        if adaptive { for y in 0..<height { rowcnt[tid * height + y] = 0 } }

        sim.agentRange(lo, hi, aidx)

        for i in lo..<hi {
            let idx = aidx[i]
            counts[tid * t + bucketOf(idx)] += 1
            if adaptive { rowcnt[tid * height + (Int(idx) >> log2w)] += 1 }
        }
    }

    /// Prefix sum over (bucket, worker) in that order, by worker 0 alone.
    /// Because each worker owns a contiguous ascending agent range, walking
    /// workers in order inside a bucket lays the agents down in ascending
    /// global index -- which is what makes the deposit chain identical to the
    /// serial one.
    func prefixBinned() {
        var running: Int32 = 0
        for b in 0..<t {
            for w in 0..<t {
                offsets[w * t + b] = running
                running += counts[w * t + b]
            }
        }
    }

    func scatterBinned(_ tid: Int) {
        let (lo, hi) = splitRange(agents, t, tid)
        for i in lo..<hi {
            let b = tid * t + bucketOf(aidx[i])
            sorted[Int(offsets[b])] = Int32(i)
            offsets[b] += 1
        }
    }

    /// Applies exactly the deposits landing in this worker's row block, in
    /// ascending agent index. Cells in other blocks are never touched.
    func depositBinned(_ tid: Int) {
        var begin = 0
        for b in 0..<tid { for w in 0..<t { begin += Int(counts[w * t + b]) } }
        var end = begin
        for w in 0..<t { end += Int(counts[w * t + tid]) }
        guard end > begin else { return }
        sim.dep.withUnsafeMutableBufferPointer { dp in
            let d = dp.baseAddress!
            for j in begin..<end { d[Int(aidx[Int(sorted[j])])] += deposit }
        }
    }

    func mergeBinned(_ tid: Int) {
        let (ylo, yhi) = splitRange(height, t, tid)
        sim.mergeRows(ylo, yhi)
        guard adaptive else { return }
        for y in ylo..<yhi {
            var sum: Int32 = 0
            for w in 0..<t { sum += rowcnt[w * height + y] }
            rowsum[y] = sum
        }
    }

    /// Recompute row boundaries so every worker gets a similar number of
    /// deposits. Cannot change the result: the partition decides *which*
    /// worker applies a deposit, never the order deposits hit a cell.
    func rebalance() {
        var total: Int64 = 0
        for y in 0..<height { total += Int64(rowsum[y]) }
        guard total > 0 else { return }
        var b: Int32 = 0
        var acc: Int64 = 0
        for y in 0..<height {
            ybucket[y] = b
            acc += Int64(rowsum[y])
            while Int(b) + 1 < t && acc * Int64(t) >= total * Int64(b + 1)
                && height - y - 1 >= t - Int(b) - 1 {
                b += 1
            }
        }
    }

    /// One tick, run by every worker. Six barriers for `binned`, matching the
    /// C reference's five phase barriers plus its handshake. The rebalance
    /// overlaps the diffusion pass, which does not read `ybucket`.
    func runTick(_ tid: Int) {
        if reduce == .binned {
            agentsBinned(tid); bar.wait()
            if tid == 0 { prefixBinned() }; bar.wait()
            scatterBinned(tid); bar.wait()
            depositBinned(tid); bar.wait()
            mergeBinned(tid); bar.wait()
            if tid == 0 && adaptive { rebalance() }
        } else {
            agentsPrivate(tid); bar.wait()
            mergePrivate(tid); bar.wait()
        }

        let (ylo, yhi) = splitRange(height, t, tid)
        sim.diffuseRows(ylo, yhi)
        bar.wait()

        // The two arrays are shared, so exactly one worker swaps them, and it
        // does so between two barriers -- everyone else is parked.
        if tid == 0 { sim.swapBuffers() }
        bar.wait()
    }
}

public struct ParallelRun {
    public let msTotal: Double
    public let tickMs: [Double]
}

public func runParallel(_ sim: Sim, warmup: UInt32, ticks: UInt32) throws -> ParallelRun {
    guard sim.cfg.update == .deferred else { throw SimError.serialNotParallel }

    let adaptive = ProcessInfo.processInfo.environment["SLIMEBENCH_NO_REBALANCE"] == nil
    let pool = Pool(sim, adaptive: adaptive)
    let total = Int(warmup + ticks)
    let t = Int(sim.cfg.threads)

    var threads: [Thread] = []
    for tid in 1..<t {
        let th = Thread {
            for _ in 0..<total { pool.runTick(tid) }
        }
        // The default 512 KiB is plenty; naming them makes `top -H` readable.
        th.name = "slimebench-\(tid)"
        th.start()
        threads.append(th)
    }

    // Worker 0 is a worker like the others; it just also holds the clock.
    // runTick ends with a barrier, so reading it here measures the whole pool.
    for _ in 0..<warmup { pool.runTick(0) }
    sim.nsAgents = 0
    sim.nsDiffuse = 0

    var tickMs: [Double] = []
    tickMs.reserveCapacity(Int(ticks))
    let start = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<ticks {
        let a = DispatchTime.now().uptimeNanoseconds
        pool.runTick(0)
        tickMs.append(Double(DispatchTime.now().uptimeNanoseconds - a) / 1e6)
    }
    let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6

    // Thread has no join; the last barrier of the last tick already released
    // everyone, so spin briefly until they have actually exited.
    for th in threads { while !th.isFinished { usleep(200) } }

    // The phases interleave, so an agent/diffuse split would be meaningless.
    sim.nsAgents = Int(ms * 1e6)
    sim.nsDiffuse = 0
    return ParallelRun(msTotal: ms, tickMs: tickMs)
}
