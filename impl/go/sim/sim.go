// Package sim is the Go implementation of SPEC-1.
//
// # Why every rounding is written out
//
// Go's specification permits an implementation to fuse floating-point
// operations -- "combine multiple floating-point operations into a single
// fused operation, possibly across statements" -- which would turn
// `acc + 4.0*g` into one FMA with one rounding instead of two. That is the
// same hazard C needs -ffp-contract=off for, except Go puts the fix in the
// language rather than in a flag: "an explicit floating-point type conversion
// rounds to the precision of the target type", and that rounding may not be
// discarded.
//
// So the stencil says `acc + float32(4.0*g)`. The conversion looks redundant
// -- both operands are already float32 -- and it is the thing that makes this
// target conformance tier A on every architecture rather than only on the one
// where the compiler happened not to fuse.
//
// # What is deliberately not done
//
// No unsafe, no manual bounds-check elision. Go has no equivalent of Rust's
// `unchecked` feature that stays within the language, and adding an unsafe
// variant would measure how much unsafe one is willing to write rather than
// what Go costs. The bounds checks stay, and §3 of docs/RESULTS.md has the
// Rust numbers for what they cost on this workload.
package sim

import (
	"math"
	"time"
)

const SpecVersion = "SPEC-1"

const (
	fnvOffset uint32 = 0x811C9DC5
	fnvPrime  uint32 = 0x01000193
)

type Update int

const (
	Serial Update = iota
	Deferred
)

func (u Update) String() string {
	if u == Deferred {
		return "deferred"
	}
	return "serial"
}

// Reduce selects the class-P deposit strategy (SPEC-1 section 5.6).
type Reduce int

const (
	Binned Reduce = iota
	Private
)

func (r Reduce) String() string {
	if r == Private {
		return "private"
	}
	return "binned"
}

type Config struct {
	Width, Height uint32
	Agents        uint32
	Ticks, Warmup uint32
	Seed          uint32
	Threads       uint32
	Update        Update
	Reduce        Reduce
	SensorDist    float32
	Step          float32
	Deposit       float32
	Decay         float32
	SensorSteps   uint32
	RotSteps      uint32
	HashEvery     uint32
	Preset        string
}

func DefaultConfig() Config {
	return Config{
		Width: 1024, Height: 1024, Agents: 262144,
		Ticks: 1000, Warmup: 0, Seed: 12345, Threads: 1,
		Update: Serial, Reduce: Binned,
		SensorDist: 9.0, Step: 1.0, Deposit: 10.0, Decay: 0.94,
		SensorSteps: 144, RotSteps: 144,
		Preset: "custom",
	}
}

// ---- PRNG (SPEC-1 section 3.1) --------------------------------------------

func splitmix32(state *uint32) uint32 {
	*state += 0x9E3779B9
	z := *state
	z = (z ^ (z >> 16)) * 0x21F0AAAD
	z = (z ^ (z >> 15)) * 0x735A2D97
	return z ^ (z >> 15)
}

func rotl32(x uint32, k uint) uint32 { return (x << k) | (x >> (32 - k)) }

// xoshiro128pp advances the four words at s[o:o+4] and returns one draw.
func xoshiro128pp(s []uint32, o int) uint32 {
	result := rotl32(s[o]+s[o+3], 7) + s[o]
	t := s[o+1] << 9
	s[o+2] ^= s[o]
	s[o+3] ^= s[o+1]
	s[o+1] ^= s[o+2]
	s[o] ^= s[o+3]
	s[o+2] ^= t
	s[o+3] = rotl32(s[o+3], 11)
	return result
}

// rnd01 is exact: u>>8 < 2^24, and 2^24 is a power of two (SPEC-1 3.2).
func rnd01(u uint32) float32 { return float32(u>>8) / 16777216.0 }

// wrapf is SPEC-1 section 2.2 -- not a modulo, a single conditional shift.
func wrapf(v, m float32) float32 {
	if v < 0.0 {
		v += m
	}
	if v >= m {
		v -= m
	}
	return v
}

// ---- simulation ------------------------------------------------------------

type Sim struct {
	Cfg   Config
	log2w uint32
	xmask uint32
	ymask uint32

	Grid    []float32
	Scratch []float32
	Dep     []float32

	Ax   []float32
	Ay   []float32
	Adir []uint16
	Arng []uint32

	cos []float32
	sin []float32

	NsAgents int64
	NsDiff   int64
}

func New(cfg Config) (*Sim, error) {
	if cfg.Width == 0 || cfg.Width&(cfg.Width-1) != 0 {
		return nil, errWidth
	}
	if cfg.Height == 0 || cfg.Height&(cfg.Height-1) != 0 {
		return nil, errHeight
	}
	cells := int(cfg.Width) * int(cfg.Height)
	n := int(cfg.Agents)

	s := &Sim{
		Cfg:     cfg,
		log2w:   uint32(log2u(cfg.Width)),
		xmask:   cfg.Width - 1,
		ymask:   cfg.Height - 1,
		Grid:    make([]float32, cells),
		Scratch: make([]float32, cells),
		Ax:      make([]float32, n),
		Ay:      make([]float32, n),
		Adir:    make([]uint16, n),
		Arng:    make([]uint32, n*4),
		cos:     make([]float32, NDIR),
		sin:     make([]float32, NDIR),
	}
	if cfg.Update == Deferred {
		s.Dep = make([]float32, cells)
	}
	for i := 0; i < NDIR; i++ {
		s.cos[i] = math.Float32frombits(CosBits[i])
		s.sin[i] = math.Float32frombits(SinBits[i])
	}
	s.init()
	return s, nil
}

func log2u(v uint32) int {
	n := 0
	for 1<<n < v {
		n++
	}
	return n
}

// init is SPEC-1 section 3.3.
func (s *Sim) init() {
	sm := s.Cfg.Seed ^ 0x5BF03635
	for i := range s.Grid {
		s.Grid[i] = float32(rnd01(splitmix32(&sm)) * 100.0)
	}

	fw := float32(s.Cfg.Width)
	fh := float32(s.Cfg.Height)
	for i := 0; i < int(s.Cfg.Agents); i++ {
		sa := s.Cfg.Seed + 0x9E3779B9*uint32(i+1)
		o := i * 4
		s.Arng[o] = splitmix32(&sa)
		s.Arng[o+1] = splitmix32(&sa)
		s.Arng[o+2] = splitmix32(&sa)
		s.Arng[o+3] = splitmix32(&sa)
		if s.Arng[o]|s.Arng[o+1]|s.Arng[o+2]|s.Arng[o+3] == 0 {
			s.Arng[o] = 1
		}
		s.Ax[i] = float32(rnd01(xoshiro128pp(s.Arng, o)) * fw)
		s.Ay[i] = float32(rnd01(xoshiro128pp(s.Arng, o)) * fh)
		s.Adir[i] = uint16(xoshiro128pp(s.Arng, o) % NDIR)
	}
}

func (s *Sim) Log2w() uint32          { return s.log2w }
func (s *Sim) Masks() (uint32, uint32) { return s.xmask, s.ymask }

// Tick is SPEC-1 section 5.2.
func (s *Sim) Tick() {
	t0 := time.Now()
	s.AgentRange(0, int(s.Cfg.Agents), nil)
	t1 := time.Now()

	if s.Dep != nil {
		s.MergeRows(0, int(s.Cfg.Height))
	}
	s.DiffuseRows(0, int(s.Cfg.Height))
	s.SwapBuffers()

	s.NsAgents += t1.Sub(t0).Nanoseconds()
	s.NsDiff += time.Since(t1).Nanoseconds()
}

func (s *Sim) SwapBuffers() { s.Grid, s.Scratch = s.Scratch, s.Grid }

// MergeRows folds Dep into Grid over rows [y0,y1) and clears it.
func (s *Sim) MergeRows(y0, y1 int) {
	if s.Dep == nil {
		return
	}
	lo := y0 << s.log2w
	hi := y1 << s.log2w
	g, d := s.Grid, s.Dep
	for i := lo; i < hi; i++ {
		g[i] += d[i]
		d[i] = 0.0
	}
}

// AgentRange is SPEC-1 section 5.3 over agents [lo,hi).
//
// With aidx non-nil the deposit is not applied; the target cell is recorded
// for a later phase to apply in a chosen order. That is the only thing the
// threaded caller does differently -- everything above it has to stay
// identical, or the parallel run stops being the same simulation.
func (s *Sim) AgentRange(lo, hi int, aidx []int32) {
	c := &s.Cfg
	grid := s.Grid
	target := s.Grid
	if s.Dep != nil {
		target = s.Dep
	}
	ax, ay, adir, arng := s.Ax, s.Ay, s.Adir, s.Arng
	cos, sin := s.cos, s.sin
	xmask, ymask, log2w := s.xmask, s.ymask, s.log2w
	fw, fh := float32(c.Width), float32(c.Height)
	sdist, step, deposit := c.SensorDist, c.Step, c.Deposit
	ss, rs := int32(c.SensorSteps), int32(c.RotSteps)
	const nd = int32(NDIR)

	// sense is inlined by hand three times below. Go's inliner does take it,
	// but writing it out keeps the ordering of the two wrapf calls visible --
	// they are normative.
	sense := func(x, y float32, d int32) float32 {
		sx := wrapf(x+float32(cos[d]*sdist), fw)
		sy := wrapf(y+float32(sin[d]*sdist), fh)
		return grid[((uint32(sy)&ymask)<<log2w)|(uint32(sx)&xmask)]
	}

	for i := lo; i < hi; i++ {
		d := int32(adir[i])
		x, y := ax[i], ay[i]

		dl := (d - ss + nd) % nd
		dr := (d + ss) % nd

		fl := sense(x, y, dl)
		fc := sense(x, y, d)
		fr := sense(x, y, dr)

		switch {
		case fc >= fl && fc >= fr:
			// straight on
		case fc < fl && fc < fr:
			// Only the dead-end case draws from the stream (SPEC-1 5.3).
			if xoshiro128pp(arng, i*4)&1 != 0 {
				d = (d + rs) % nd
			} else {
				d = (d - rs + nd) % nd
			}
		case fl > fr:
			d = (d - rs + nd) % nd
		default:
			d = (d + rs) % nd
		}

		x = wrapf(x+float32(cos[d]*step), fw)
		y = wrapf(y+float32(sin[d]*step), fh)

		idx := ((uint32(y) & ymask) << log2w) | (uint32(x) & xmask)
		if aidx == nil {
			target[idx] += deposit
		} else {
			aidx[i] = int32(idx)
		}

		adir[i] = uint16(d)
		ax[i], ay[i] = x, y
	}
}

// DiffuseRows is SPEC-1 section 5.4 over rows [y0,y1), writing into Scratch.
// Summation order is normative -- do not reorder. Output cells are
// independent, so splitting the row range across goroutines is
// unconditionally bit-identical.
func (s *Sim) DiffuseRows(y0, y1 int) {
	w := s.Cfg.Width
	log2w, xmask, ymask := s.log2w, s.xmask, s.ymask
	decay := s.Cfg.Decay
	src, dst := s.Grid, s.Scratch

	for y := uint32(y0); y < uint32(y1); y++ {
		rowm := ((y - 1) & ymask) << log2w
		row0 := y << log2w
		rowp := ((y + 1) & ymask) << log2w

		for x := uint32(0); x < w; x++ {
			xm := (x - 1) & xmask
			xp := (x + 1) & xmask

			acc := src[rowm|xm]
			acc = acc + src[rowm|x]
			acc = acc + src[rowm|xp]
			acc = acc + src[row0|xm]
			// The conversion is what forbids an FMA here; see the package doc.
			acc = acc + float32(4.0*src[row0|x])
			acc = acc + src[row0|xp]
			acc = acc + src[rowp|xm]
			acc = acc + src[rowp|x]
			acc = acc + src[rowp|xp]

			dst[row0|x] = float32(float32(acc/12.0) * decay)
		}
	}
}

// ---- checksums (SPEC-1 section 6) ------------------------------------------

func (s *Sim) HashGrid() uint32 {
	h := fnvOffset
	for _, v := range s.Grid {
		h = (h ^ math.Float32bits(v)) * fnvPrime
	}
	return h
}

func (s *Sim) HashAgents() uint32 {
	h := fnvOffset
	for i := 0; i < int(s.Cfg.Agents); i++ {
		h = (h ^ math.Float32bits(s.Ax[i])) * fnvPrime
		h = (h ^ math.Float32bits(s.Ay[i])) * fnvPrime
		h = (h ^ uint32(s.Adir[i])) * fnvPrime
	}
	return h
}

func DirtableHashRuntime() uint32 {
	h := fnvOffset
	for _, b := range CosBits {
		h = (h ^ b) * fnvPrime
	}
	for _, b := range SinBits {
		h = (h ^ b) * fnvPrime
	}
	return h
}

// RenderGray is SPEC-1 section 11, for the windowed frontends.
func (s *Sim) RenderGray(out []uint8, displayMax float32) {
	scale := 255.0 / displayMax
	for i, v := range s.Grid {
		b := int32(v * scale)
		if b < 0 {
			b = 0
		} else if b > 255 {
			b = 255
		}
		out[i] = uint8(b)
	}
}

type simError string

func (e simError) Error() string { return string(e) }

const (
	errWidth  = simError("width must be a power of two")
	errHeight = simError("height must be a power of two")
)
