// Multi-threaded tick (SPEC-1 section 5.6, benchmark class P).
//
// Both reduction strategies, the same phase order and the same deposit order
// as the C reference, so `binned` is bit-identical to the single-threaded run
// here too. The agent rule and the stencil are not reimplemented: this file
// calls Sim.AgentRange and Sim.DiffuseRows, the same code the serial path uses.
//
// # The barrier
//
// Go's standard library has no barrier. sync.WaitGroup is the obvious
// substitute -- Add(n), each worker Done(), everyone Wait() -- but a WaitGroup
// is single-use, so a six-phase tick would allocate and re-Add six of them per
// tick, and the workers would need a second signal to know the next phase had
// started. The sense-reversing barrier below is one mutex and one condition
// variable, reused for the whole run.
//
// Goroutines are pinned to nothing: Go has no affinity API, and GOMAXPROCS is
// set to the thread count so the scheduler has exactly as many Ps as workers.
package sim

import (
	"os"
	"sync"
	"time"
)

type barrier struct {
	n     int
	mu    sync.Mutex
	cv    *sync.Cond
	count int
	sense bool
}

func newBarrier(n int) *barrier {
	b := &barrier{n: n}
	b.cv = sync.NewCond(&b.mu)
	return b
}

func (b *barrier) wait() {
	b.mu.Lock()
	my := !b.sense
	b.count++
	if b.count == b.n {
		b.count = 0
		b.sense = my
		b.cv.Broadcast()
	} else {
		for b.sense != my {
			b.cv.Wait()
		}
	}
	b.mu.Unlock()
}

// split is a contiguous split of [0,n) into `parts`; part i is [lo,hi).
// Identical to the C reference's split, deliberately: the partition is what
// makes `binned` reproduce the serial deposit order.
func split(n, parts, i int) (int, int) {
	base, rem := n/parts, n%parts
	lo := i*base + min(i, rem)
	hi := lo + base
	if i < rem {
		hi++
	}
	return lo, hi
}

type pool struct {
	s        *Sim
	t        int
	cells    int
	agents   int
	height   int
	log2w    uint32
	deposit  float32
	reduce   Reduce
	adaptive bool
	bar      *barrier

	aidx    []int32
	sorted  []int32
	counts  []int32
	offsets []int32
	ybucket []int32
	rowcnt  []int32
	rowsum  []int32
	priv    []float32
}

func (p *pool) bucketOf(idx int32) int { return int(p.ybucket[int(idx)>>p.log2w]) }

// ---- Reduce::Private -------------------------------------------------------

func (p *pool) agentsPrivate(tid int) {
	lo, hi := split(p.agents, p.t, tid)
	p.s.AgentRange(lo, hi, p.aidx)
	base := tid * p.cells
	for i := lo; i < hi; i++ {
		p.priv[base+int(p.aidx[i])] += p.deposit
	}
}

// mergePrivate uses a fixed worker order, so the result is reproducible for
// this worker count. It is NOT in general the same grouping as the serial
// chain -- SPEC-1 section 5.6.
func (p *pool) mergePrivate(tid int) {
	lo, hi := split(p.cells, p.t, tid)
	g := p.s.Grid
	for i := lo; i < hi; i++ {
		acc := p.priv[i]
		p.priv[i] = 0
		for k := 1; k < p.t; k++ {
			acc += p.priv[k*p.cells+i]
			p.priv[k*p.cells+i] = 0
		}
		g[i] += acc
	}
}

// ---- Reduce::Binned --------------------------------------------------------

func (p *pool) agentsBinned(tid int) {
	lo, hi := split(p.agents, p.t, tid)
	cnt := p.counts[tid*p.t : (tid+1)*p.t]
	for i := range cnt {
		cnt[i] = 0
	}
	var rc []int32
	if p.adaptive {
		rc = p.rowcnt[tid*p.height : (tid+1)*p.height]
		for i := range rc {
			rc[i] = 0
		}
	}

	p.s.AgentRange(lo, hi, p.aidx)

	for i := lo; i < hi; i++ {
		idx := p.aidx[i]
		cnt[p.bucketOf(idx)]++
		if p.adaptive {
			rc[int(idx)>>p.log2w]++
		}
	}
}

// prefixBinned is the prefix sum over (bucket, worker) in that order, by
// worker 0 alone. Because each worker owns a contiguous ascending agent range,
// walking workers in order inside a bucket lays the agents down in ascending
// global index -- which is what makes the deposit chain identical to the
// serial one.
func (p *pool) prefixBinned() {
	running := int32(0)
	for b := 0; b < p.t; b++ {
		for w := 0; w < p.t; w++ {
			p.offsets[w*p.t+b] = running
			running += p.counts[w*p.t+b]
		}
	}
}

func (p *pool) scatterBinned(tid int) {
	lo, hi := split(p.agents, p.t, tid)
	off := p.offsets[tid*p.t : (tid+1)*p.t]
	for i := lo; i < hi; i++ {
		b := p.bucketOf(p.aidx[i])
		p.sorted[off[b]] = int32(i)
		off[b]++
	}
}

// depositBinned applies exactly the deposits landing in this worker's row
// block, in ascending agent index. Cells in other blocks are never touched.
func (p *pool) depositBinned(tid int) {
	begin := 0
	for b := 0; b < tid; b++ {
		for w := 0; w < p.t; w++ {
			begin += int(p.counts[w*p.t+b])
		}
	}
	end := begin
	for w := 0; w < p.t; w++ {
		end += int(p.counts[w*p.t+tid])
	}
	dep := p.s.Dep
	for j := begin; j < end; j++ {
		dep[p.aidx[p.sorted[j]]] += p.deposit
	}
}

func (p *pool) mergeBinned(tid int) {
	ylo, yhi := split(p.height, p.t, tid)
	p.s.MergeRows(ylo, yhi)
	if !p.adaptive {
		return
	}
	for y := ylo; y < yhi; y++ {
		var sum int32
		for w := 0; w < p.t; w++ {
			sum += p.rowcnt[w*p.height+y]
		}
		p.rowsum[y] = sum
	}
}

// rebalance recomputes row boundaries so every worker gets a similar number of
// deposits. It cannot change the result: the partition decides which worker
// applies a deposit, never the order deposits hit a cell.
func (p *pool) rebalance() {
	var total int64
	for _, v := range p.rowsum {
		total += int64(v)
	}
	if total == 0 {
		return
	}
	b, acc := int32(0), int64(0)
	for y := 0; y < p.height; y++ {
		p.ybucket[y] = b
		acc += int64(p.rowsum[y])
		for int(b)+1 < p.t && acc*int64(p.t) >= total*int64(b+1) &&
			p.height-y-1 >= p.t-int(b)-1 {
			b++
		}
	}
}

// runTick is one tick, run by every worker. Six barriers for `binned`,
// matching the C reference's five phase barriers plus its handshake. The
// rebalance overlaps the diffusion pass, which does not read ybucket.
func (p *pool) runTick(tid int) {
	if p.reduce == Binned {
		p.agentsBinned(tid)
		p.bar.wait()
		if tid == 0 {
			p.prefixBinned()
		}
		p.bar.wait()
		p.scatterBinned(tid)
		p.bar.wait()
		p.depositBinned(tid)
		p.bar.wait()
		p.mergeBinned(tid)
		p.bar.wait()
		if tid == 0 && p.adaptive {
			p.rebalance()
		}
	} else {
		p.agentsPrivate(tid)
		p.bar.wait()
		p.mergePrivate(tid)
		p.bar.wait()
	}

	ylo, yhi := split(p.height, p.t, tid)
	p.s.DiffuseRows(ylo, yhi)
	p.bar.wait()

	// The two slice headers are shared, so exactly one worker swaps them, and
	// it does so between two barriers -- everyone else is parked.
	if tid == 0 {
		p.s.SwapBuffers()
	}
	p.bar.wait()
}

// Run is the result of a class-P run.
type Run struct {
	MsTotal float64
	TickMs  []float64
}

// RunParallel runs warmup+ticks ticks across cfg.Threads goroutines.
func RunParallel(s *Sim, warmup, ticks uint32) (*Run, error) {
	c := s.Cfg
	if c.Update != Deferred {
		return nil, simError(
			"--threads > 1 requires --update deferred.\n" +
				"       SPEC-1 'serial' makes an agent's deposit visible to the\n" +
				"       next agent in the same tick, which is a sequential\n" +
				"       dependency; see SPEC-1 section 5.5.")
	}
	t := int(c.Threads)
	cells := int(c.Width) * int(c.Height)
	h := int(c.Height)
	binned := c.Reduce == Binned

	p := &pool{
		s: s, t: t, cells: cells, agents: int(c.Agents), height: h,
		log2w: s.log2w, deposit: c.Deposit, reduce: c.Reduce,
		adaptive: binned && os.Getenv("SLIMEBENCH_NO_REBALANCE") == "",
		bar:      newBarrier(t),
		aidx:     make([]int32, c.Agents),
	}
	if binned {
		p.sorted = make([]int32, c.Agents)
		p.counts = make([]int32, t*t)
		p.offsets = make([]int32, t*t)
		p.ybucket = make([]int32, h)
		// Row -> owning worker, same split as the diffusion pass so a worker's
		// deposits land in rows it already touches.
		for b := 0; b < t; b++ {
			lo, hi := split(h, t, b)
			for y := lo; y < hi; y++ {
				p.ybucket[y] = int32(b)
			}
		}
		if p.adaptive {
			p.rowcnt = make([]int32, t*h)
			p.rowsum = make([]int32, h)
		}
	} else {
		p.priv = make([]float32, t*cells)
	}

	total := int(warmup + ticks)
	var wg sync.WaitGroup
	for tid := 1; tid < t; tid++ {
		wg.Add(1)
		go func(tid int) {
			defer wg.Done()
			for i := 0; i < total; i++ {
				p.runTick(tid)
			}
		}(tid)
	}

	// Worker 0 is a worker like the others; it just also holds the clock.
	// runTick ends with a barrier, so reading it here measures the whole pool
	// rather than worker 0's own progress.
	for i := uint32(0); i < warmup; i++ {
		p.runTick(0)
	}
	tickMs := make([]float64, 0, ticks)
	start := time.Now()
	for i := uint32(0); i < ticks; i++ {
		a := time.Now()
		p.runTick(0)
		tickMs = append(tickMs, float64(time.Since(a).Nanoseconds())/1e6)
	}
	ms := float64(time.Since(start).Nanoseconds()) / 1e6
	wg.Wait()

	// The phases interleave, so an agent/diffuse split would be meaningless.
	s.NsAgents = int64(ms * 1e6)
	s.NsDiff = 0
	return &Run{MsTotal: ms, TickMs: tickMs}, nil
}
