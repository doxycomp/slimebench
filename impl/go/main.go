// slimebench -- Go headless benchmark (classes S and P).
package main

import (
	"fmt"
	"os"
	"runtime"
	"sort"
	"strconv"
	"time"

	"slimebench/sim"
)

const usage = `usage: slimebench [options]   (slimebench SPEC-1)
  --preset NAME        tiny|small|medium|large|huge|browser
  --width N --height N powers of two
  --agents N  --ticks N  --warmup N  --seed N
  --update MODE        serial|deferred
  --threads N
  --deposit-reduce M   private|binned  (SPEC-1 5.6)
  --sensor-dist F  --sensor-steps N  --rot-steps N
  --step F  --deposit F  --decay F
  --headless  --json  --hash-every N
  -h, --help`

func fail(msg string) {
	fmt.Fprintf(os.Stderr, "error: %s\n%s\n", msg, usage)
	os.Exit(2)
}

func preset(name string) (w, h, a, t uint32, ok bool) {
	switch name {
	case "tiny":
		return 512, 512, 65536, 1000, true
	case "small":
		return 1024, 1024, 262144, 1000, true
	case "medium":
		return 2048, 2048, 1048576, 1000, true
	case "large":
		return 4096, 4096, 4194304, 500, true
	case "huge":
		return 8192, 8192, 16777216, 100, true
	case "browser":
		return 1024, 1024, 262144, 0, true
	}
	return 0, 0, 0, 0, false
}

func main() {
	cfg := sim.DefaultConfig()
	wantJSON := false

	args := os.Args[1:]
	u32 := func(s string) uint32 {
		v, err := strconv.ParseUint(s, 10, 32)
		if err != nil {
			fail("'" + s + "' is not an integer")
		}
		return uint32(v)
	}
	f32 := func(s string) float32 {
		v, err := strconv.ParseFloat(s, 32)
		if err != nil {
			fail("'" + s + "' is not a number")
		}
		return float32(v)
	}

	for i := 0; i < len(args); i++ {
		a := args[i]
		next := func() string {
			if i+1 >= len(args) {
				fail(a + " requires a value")
			}
			i++
			return args[i]
		}
		switch a {
		case "-h", "--help":
			fmt.Println(usage)
			return
		case "--json":
			wantJSON = true
		case "--headless", "--no-simd":
			// accepted and ignored: this target is headless and scalar
		case "--simd":
			fail("this target has no vectorised kernel")
		case "--preset":
			n := next()
			w, h, ag, t, ok := preset(n)
			if !ok {
				fail("unknown preset '" + n + "'")
			}
			cfg.Width, cfg.Height, cfg.Agents, cfg.Ticks = w, h, ag, t
			cfg.Preset = n
		case "--width":
			cfg.Width = u32(next())
			cfg.Preset = "custom"
		case "--height":
			cfg.Height = u32(next())
			cfg.Preset = "custom"
		case "--agents":
			cfg.Agents = u32(next())
			cfg.Preset = "custom"
		case "--ticks":
			cfg.Ticks = u32(next())
		case "--warmup":
			cfg.Warmup = u32(next())
		case "--seed":
			cfg.Seed = u32(next())
		case "--threads":
			cfg.Threads = u32(next())
		case "--hash-every":
			cfg.HashEvery = u32(next())
		case "--sensor-steps":
			cfg.SensorSteps = u32(next())
		case "--rot-steps":
			cfg.RotSteps = u32(next())
		case "--sensor-dist":
			cfg.SensorDist = f32(next())
		case "--step":
			cfg.Step = f32(next())
		case "--deposit":
			cfg.Deposit = f32(next())
		case "--decay":
			cfg.Decay = f32(next())
		case "--display-max", "--dump-grid":
			next() // accepted for CLI compatibility, unused here
		case "--update":
			switch next() {
			case "serial":
				cfg.Update = sim.Serial
			case "deferred":
				cfg.Update = sim.Deferred
			default:
				fail("--update must be serial|deferred")
			}
		case "--deposit-reduce":
			switch next() {
			case "binned":
				cfg.Reduce = sim.Binned
			case "private":
				cfg.Reduce = sim.Private
			default:
				fail("--deposit-reduce must be private|binned")
			}
		default:
			// SPEC-1 section 10: never silently ignore an unknown flag.
			fail("unknown argument '" + a + "'")
		}
	}

	s, err := sim.New(cfg)
	if err != nil {
		fmt.Fprintf(os.Stderr, "error: %v\n", err)
		os.Exit(1)
	}

	class := "S"
	var msTotal float64
	var tickMs []float64

	if cfg.Threads > 1 {
		class = "P"
		// One OS thread per worker; without this the runtime is free to
		// schedule sixteen goroutines onto four Ps and the thread sweep
		// measures the scheduler.
		runtime.GOMAXPROCS(int(cfg.Threads))
		r, err := sim.RunParallel(s, cfg.Warmup, cfg.Ticks)
		if err != nil {
			fmt.Fprintf(os.Stderr, "error: %v\n", err)
			os.Exit(2)
		}
		msTotal, tickMs = r.MsTotal, r.TickMs
	} else {
		for i := uint32(0); i < cfg.Warmup; i++ {
			s.Tick()
		}
		s.NsAgents, s.NsDiff = 0, 0

		tickMs = make([]float64, 0, cfg.Ticks)
		start := time.Now()
		for t := uint32(0); t < cfg.Ticks; t++ {
			a := time.Now()
			s.Tick()
			tickMs = append(tickMs, float64(time.Since(a).Nanoseconds())/1e6)
			if cfg.HashEvery != 0 && (t+1)%cfg.HashEvery == 0 {
				fmt.Fprintf(os.Stderr, "tick %d grid=0x%08X agents=0x%08X\n",
					t+1, s.HashGrid(), s.HashAgents())
			}
		}
		msTotal = float64(time.Since(start).Nanoseconds()) / 1e6
	}

	variant := "scalar"
	if cfg.Threads > 1 {
		variant = cfg.Reduce.String()
	}

	if wantJSON {
		fmt.Println(resultJSON(s, class, variant, msTotal, tickMs))
	} else {
		fmt.Printf("%s %dx%d agents=%d ticks=%d update=%s",
			cfg.Preset, cfg.Width, cfg.Height, cfg.Agents, cfg.Ticks, cfg.Update)
		if cfg.Threads > 1 {
			fmt.Printf(" threads=%d reduce=%s", cfg.Threads, cfg.Reduce)
		}
		fmt.Println()
		fmt.Printf("  grid_hash  0x%08X\n", s.HashGrid())
		fmt.Printf("  agent_hash 0x%08X\n", s.HashAgents())
		per := 0.0
		if cfg.Ticks > 0 {
			per = msTotal / float64(cfg.Ticks)
		}
		fmt.Printf("  total      %.2f ms  (%.4f ms/tick)\n", msTotal, per)
		fmt.Printf("  agents     %.2f ms\n", float64(s.NsAgents)/1e6)
		fmt.Printf("  diffuse    %.2f ms\n", float64(s.NsDiff)/1e6)
	}
}

func resultJSON(s *sim.Sim, class, variant string, msTotal float64, tickMs []float64) string {
	n := len(tickMs)
	sorted := append([]float64(nil), tickMs...)
	sort.Float64s(sorted)
	median, p99, mean := 0.0, 0.0, 0.0
	if n > 0 {
		median = sorted[n/2]
		i99 := int(float64(n) * 0.99)
		if i99 >= n {
			i99 = n - 1
		}
		p99 = sorted[i99]
		for _, v := range tickMs {
			mean += v
		}
		mean /= float64(n)
	}
	c := s.Cfg
	cells := float64(c.Width) * float64(c.Height)
	maups, mcups := 0.0, 0.0
	if msTotal > 0 {
		maups = float64(c.Agents) * float64(n) / msTotal / 1000
		mcups = cells * float64(n) / msTotal / 1000
	}
	return fmt.Sprintf(
		`{"schema":1,"impl":"go","backend":"headless","class":"%s","preset":"%s",`+
			`"variant":"%s","width":%d,"height":%d,"agents":%d,"ticks":%d,"seed":%d,`+
			`"update":"%s","threads":%d,`+
			`"grid_hash":"0x%08X","agent_hash":"0x%08X","dirtable_hash":"0x%08X",`+
			`"ms_total":%.4f,"ms_agents":%.4f,"ms_diffuse":%.4f,`+
			`"ms_per_tick_mean":%.6f,"ms_per_tick_median":%.6f,"ms_per_tick_p99":%.6f,`+
			`"maups":%.4f,"mcups":%.4f}`,
		class, c.Preset, variant, c.Width, c.Height, c.Agents, n, c.Seed,
		c.Update, c.Threads,
		s.HashGrid(), s.HashAgents(), sim.DirtableHashRuntime(),
		msTotal, float64(s.NsAgents)/1e6, float64(s.NsDiff)/1e6,
		mean, median, p99, maups, mcups)
}
