// slimebench -- CUDA implementation of SPEC-1 (benchmark class G).
//
// ## What class G actually measures
//
// Not the language. The host code here allocates buffers and launches three
// kernels; Rust or Python would produce the same numbers. This target is the
// ceiling for the problem on this hardware, and the report says so.
//
// ## Why this can still be conformance tier A
//
// SPEC-1 section 8 assumed GPU work lands in tier C. Three things have to hold
// for that assumption to be wrong, and all three do here:
//
//   1. The diffusion pass is element-wise with a fixed summation order, one
//      output cell per thread. Same argument as the SIMD kernel (SPEC-1 8.1),
//      so it needs -fmad=false to stop nvcc contracting `4.0f*c + acc` into an
//      FMA, and the default precise division for `/12.0f`.
//
//   2. The agent pass is per-agent and reads a read-only grid in `deferred`
//      mode. The PRNG, the direction table and the wrap arithmetic are all
//      integer or exact-f32 operations that CUDA implements to IEEE rules.
//
//   3. The deposits are the hard part. `atomicAdd(float*)` is the obvious
//      choice and is NOT deterministic -- the order threads land decides the
//      rounding. Instead this counts deposits per cell with `atomicAdd(unsigned*)`,
//      which is exact and order-independent because integer addition is, and
//      then computes `grid[i] += count[i] * deposit` once.
//
//      `k * deposit` equals the serial chain of k additions whenever the
//      partial sums are exactly representable -- with the default deposit of
//      10.0 and realistic hit counts, k*10 stays far below 2^24. That is the
//      same caveat SPEC-1 5.6 already documents for the CPU `private`
//      strategy, and the harness verifies it rather than assuming it.
//
// `serial` mode is refused: an agent seeing the previous agent's deposit
// within the same tick is a sequential dependency, and a GPU has nothing to
// offer there.

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <string>
#include <vector>
#include <algorithm>
#include <numeric>

// The generated direction table is plain C. Sharing it rather than emitting a
// fourth copy keeps the "byte-identical by construction" guarantee of SPEC-1 4.
#include "../c/dirtable.h"

#define SPEC_VERSION "SPEC-1"

#define CUDA_OK(call)                                                        \
    do {                                                                     \
        cudaError_t _e = (call);                                             \
        if (_e != cudaSuccess) {                                             \
            std::fprintf(stderr, "cuda error %s at %s:%d\n",                 \
                         cudaGetErrorString(_e), __FILE__, __LINE__);        \
            std::exit(1);                                                    \
        }                                                                    \
    } while (0)

// ---- device-side helpers, mirroring SPEC-1 sections 2 and 3 --------------

__device__ __forceinline__ unsigned rotl32(unsigned x, int k) {
    return (x << k) | (x >> (32 - k));
}

__device__ __forceinline__ unsigned xoshiro128pp(unsigned *s) {
    const unsigned result = rotl32(s[0] + s[3], 7) + s[0];
    const unsigned t = s[1] << 9;
    s[2] ^= s[0];
    s[3] ^= s[1];
    s[1] ^= s[2];
    s[0] ^= s[3];
    s[2] ^= t;
    s[3] = rotl32(s[3], 11);
    return result;
}

__device__ __forceinline__ float wrapf(float v, float m) {
    if (v < 0.0f) v = v + m;
    if (v >= m) v = v - m;
    return v;
}

struct DevCfg {
    unsigned width, height, log2w, xmask, ymask;
    unsigned agents;
    float sensor_dist, step, deposit, decay;
    int ss, rs;
};

__constant__ DevCfg g_cfg;
__constant__ float g_cos[SB_NDIR];
__constant__ float g_sin[SB_NDIR];

__device__ __forceinline__ float sense(const float *grid, float x, float y, int d) {
    const float sx = wrapf(x + g_cos[d] * g_cfg.sensor_dist, (float)g_cfg.width);
    const float sy = wrapf(y + g_sin[d] * g_cfg.sensor_dist, (float)g_cfg.height);
    return grid[((unsigned)sy & g_cfg.ymask) << g_cfg.log2w |
                ((unsigned)sx & g_cfg.xmask)];
}

// SPEC-1 section 5.3, deferred mode. One thread per agent.
__global__ void k_agents(const float *__restrict grid, unsigned *__restrict depcount,
                         float *ax, float *ay, unsigned short *adir, unsigned *arng) {
    const unsigned i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= g_cfg.agents) return;

    const int ndir = SB_NDIR;
    int d = adir[i];
    float x = ax[i];
    float y = ay[i];

    const int dl = (d - g_cfg.ss + ndir) % ndir;
    const int dr = (d + g_cfg.ss) % ndir;

    const float fl = sense(grid, x, y, dl);
    const float fc = sense(grid, x, y, d);
    const float fr = sense(grid, x, y, dr);

    if (fc >= fl && fc >= fr) {
        // straight on
    } else if (fc < fl && fc < fr) {
        unsigned *r = &arng[(size_t)i * 4];
        unsigned s[4] = {r[0], r[1], r[2], r[3]};
        const unsigned v = xoshiro128pp(s);
        r[0] = s[0]; r[1] = s[1]; r[2] = s[2]; r[3] = s[3];
        d = (v & 1u) ? (d + g_cfg.rs) % ndir : (d - g_cfg.rs + ndir) % ndir;
    } else if (fl > fr) {
        d = (d - g_cfg.rs + ndir) % ndir;
    } else {
        d = (d + g_cfg.rs) % ndir;
    }

    x = wrapf(x + g_cos[d] * g_cfg.step, (float)g_cfg.width);
    y = wrapf(y + g_sin[d] * g_cfg.step, (float)g_cfg.height);

    const unsigned idx = (((unsigned)y & g_cfg.ymask) << g_cfg.log2w) |
                         ((unsigned)x & g_cfg.xmask);

    // Integer atomic: exact and order-independent, unlike atomicAdd(float*).
    atomicAdd(&depcount[idx], 1u);

    adir[i] = (unsigned short)d;
    ax[i] = x;
    ay[i] = y;
}

// grid += count * deposit, then clear the counts.
__global__ void k_merge(float *__restrict grid, unsigned *__restrict depcount,
                        unsigned cells) {
    const unsigned i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= cells) return;
    const unsigned c = depcount[i];
    if (c) {
        grid[i] = grid[i] + (float)c * g_cfg.deposit;
        depcount[i] = 0u;
    }
}

// SPEC-1 section 5.4. Summation order is normative -- do not reorder, and the
// build must pass -fmad=false so the 4.0f*c term is not fused into the add.
__global__ void k_diffuse(const float *__restrict src, float *__restrict dst,
                          unsigned cells) {
    const unsigned i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= cells) return;

    const unsigned x = i & g_cfg.xmask;
    const unsigned y = i >> g_cfg.log2w;
    const unsigned xm = (x - 1u) & g_cfg.xmask;
    const unsigned xp = (x + 1u) & g_cfg.xmask;
    const unsigned rowm = ((y - 1u) & g_cfg.ymask) << g_cfg.log2w;
    const unsigned row0 = y << g_cfg.log2w;
    const unsigned rowp = ((y + 1u) & g_cfg.ymask) << g_cfg.log2w;

    float acc = src[rowm | xm];
    acc = acc + src[rowm | x];
    acc = acc + src[rowm | xp];
    acc = acc + src[row0 | xm];
    acc = acc + 4.0f * src[row0 | x];
    acc = acc + src[row0 | xp];
    acc = acc + src[rowp | xm];
    acc = acc + src[rowp | x];
    acc = acc + src[rowp | xp];

    dst[row0 | x] = (acc / 12.0f) * g_cfg.decay;
}

// ---- host ----------------------------------------------------------------

static unsigned splitmix32(unsigned &state) {
    state += 0x9E3779B9u;
    unsigned z = state;
    z = (z ^ (z >> 16)) * 0x21F0AAADu;
    z = (z ^ (z >> 15)) * 0x735A2D97u;
    return z ^ (z >> 15);
}

static unsigned h_rotl32(unsigned x, int k) { return (x << k) | (x >> (32 - k)); }

static unsigned h_xoshiro(unsigned *s) {
    const unsigned result = h_rotl32(s[0] + s[3], 7) + s[0];
    const unsigned t = s[1] << 9;
    s[2] ^= s[0]; s[3] ^= s[1]; s[1] ^= s[2]; s[0] ^= s[3];
    s[2] ^= t; s[3] = h_rotl32(s[3], 11);
    return result;
}

static float rnd01(unsigned u) { return (float)(u >> 8) / 16777216.0f; }

static unsigned fnv(unsigned h, unsigned w) { return (h ^ w) * 0x01000193u; }

static double now_ms() {
    timespec ts{};
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1e3 + ts.tv_nsec / 1e6;
}

struct Opts {
    unsigned width = 1024, height = 1024, agents = 262144;
    unsigned ticks = 1000, warmup = 0, seed = 12345;
    float sensor_dist = 9.0f, step = 1.0f, deposit = 10.0f, decay = 0.94f;
    unsigned ss = 144, rs = 144, hash_every = 0;
    std::string preset = "custom";
    bool json = false;
    std::string dump_grid;
};

static void usage(std::FILE *f, const char *a0) {
    std::fprintf(f,
        "usage: %s [options]   (slimebench %s, CUDA, class G)\n"
        "  --preset NAME        tiny|small|medium|large|browser\n"
        "  --width N --height N powers of two\n"
        "  --agents N  --ticks N  --warmup N  --seed N\n"
        "  --update MODE        deferred only (serial is refused)\n"
        "  --sensor-dist F  --sensor-steps N  --rot-steps N\n"
        "  --step F  --deposit F  --decay F\n"
        "  --headless  --json  --hash-every N  --dump-grid PATH\n"
        "  -h, --help\n", a0, SPEC_VERSION);
}

int main(int argc, char **argv) {
    Opts o;

    auto need = [&](int &i) -> const char * {
        if (i + 1 >= argc) {
            std::fprintf(stderr, "error: %s requires a value\n", argv[i]);
            std::exit(2);
        }
        return argv[++i];
    };

    for (int i = 1; i < argc; i++) {
        const std::string a = argv[i];
        if (a == "-h" || a == "--help") { usage(stdout, argv[0]); return 0; }
        else if (a == "--preset") {
            const std::string p = need(i);
            if (p == "tiny")        { o.width=512;  o.height=512;  o.agents=65536;   o.ticks=1000; }
            else if (p == "small")  { o.width=1024; o.height=1024; o.agents=262144;  o.ticks=1000; }
            else if (p == "medium") { o.width=2048; o.height=2048; o.agents=1048576; o.ticks=1000; }
            else if (p == "large")  { o.width=4096; o.height=4096; o.agents=4194304; o.ticks=500; }
            else if (p == "browser"){ o.width=1024; o.height=1024; o.agents=262144;  o.ticks=0; }
            else { std::fprintf(stderr, "error: unknown preset '%s'\n", p.c_str()); return 2; }
            o.preset = p;
        }
        else if (a == "--width")  { o.width  = std::stoul(need(i)); o.preset = "custom"; }
        else if (a == "--height") { o.height = std::stoul(need(i)); o.preset = "custom"; }
        else if (a == "--agents") { o.agents = std::stoul(need(i)); o.preset = "custom"; }
        else if (a == "--ticks")  { o.ticks  = std::stoul(need(i)); }
        else if (a == "--warmup") { o.warmup = std::stoul(need(i)); }
        else if (a == "--seed")   { o.seed   = std::stoul(need(i)); }
        else if (a == "--hash-every")   { o.hash_every = std::stoul(need(i)); }
        else if (a == "--sensor-steps") { o.ss = std::stoul(need(i)); }
        else if (a == "--rot-steps")    { o.rs = std::stoul(need(i)); }
        else if (a == "--sensor-dist")  { o.sensor_dist = std::stof(need(i)); }
        else if (a == "--step")         { o.step = std::stof(need(i)); }
        else if (a == "--deposit")      { o.deposit = std::stof(need(i)); }
        else if (a == "--decay")        { o.decay = std::stof(need(i)); }
        else if (a == "--dump-grid")    { o.dump_grid = need(i); }
        else if (a == "--update") {
            const std::string m = need(i);
            if (m == "deferred") { /* the only supported mode */ }
            else if (m == "serial") {
                std::fprintf(stderr,
                    "error: the CUDA target implements --update deferred only.\n"
                    "       SPEC-1 'serial' makes an agent's deposit visible to\n"
                    "       the next agent in the same tick, a sequential\n"
                    "       dependency a GPU cannot express.\n");
                return 3;
            } else {
                std::fprintf(stderr, "error: --update must be serial|deferred\n");
                return 2;
            }
        }
        else if (a == "--headless") { }
        else if (a == "--threads")  { need(i); }   // meaningless here, accepted
        else if (a == "--json")     { o.json = true; }
        else {
            // SPEC-1 section 10: never silently ignore an unknown flag.
            std::fprintf(stderr, "error: unknown argument '%s'\n", argv[i]);
            usage(stderr, argv[0]);
            return 2;
        }
    }

    if (!o.width || (o.width & (o.width - 1)) ||
        !o.height || (o.height & (o.height - 1))) {
        std::fprintf(stderr, "error: width and height must be powers of two\n");
        return 2;
    }

    const size_t cells = (size_t)o.width * o.height;
    unsigned log2w = 0; while ((1u << log2w) < o.width) log2w++;

    // ---- host-side init, identical to SPEC-1 section 3.3 ------------------
    std::vector<float> grid(cells);
    unsigned sm = o.seed ^ 0x5BF03635u;
    for (size_t i = 0; i < cells; i++) grid[i] = rnd01(splitmix32(sm)) * 100.0f;

    std::vector<float> ax(o.agents), ay(o.agents);
    std::vector<unsigned short> adir(o.agents);
    std::vector<unsigned> arng((size_t)o.agents * 4);
    const float fw = (float)o.width, fh = (float)o.height;
    for (unsigned i = 0; i < o.agents; i++) {
        unsigned a = o.seed + 0x9E3779B9u * (i + 1u);
        unsigned *r = &arng[(size_t)i * 4];
        r[0] = splitmix32(a); r[1] = splitmix32(a);
        r[2] = splitmix32(a); r[3] = splitmix32(a);
        if ((r[0] | r[1] | r[2] | r[3]) == 0u) r[0] = 1u;
        ax[i] = rnd01(h_xoshiro(r)) * fw;
        ay[i] = rnd01(h_xoshiro(r)) * fh;
        adir[i] = (unsigned short)(h_xoshiro(r) % SB_NDIR);
    }

    // ---- device setup -----------------------------------------------------
    DevCfg dc{};
    dc.width = o.width; dc.height = o.height; dc.log2w = log2w;
    dc.xmask = o.width - 1u; dc.ymask = o.height - 1u;
    dc.agents = o.agents;
    dc.sensor_dist = o.sensor_dist; dc.step = o.step;
    dc.deposit = o.deposit; dc.decay = o.decay;
    dc.ss = (int)o.ss; dc.rs = (int)o.rs;
    CUDA_OK(cudaMemcpyToSymbol(g_cfg, &dc, sizeof dc));

    std::vector<float> hcos(SB_NDIR), hsin(SB_NDIR);
    for (int d = 0; d < SB_NDIR; d++) {
        std::memcpy(&hcos[d], &SB_COS_BITS[d], 4);
        std::memcpy(&hsin[d], &SB_SIN_BITS[d], 4);
    }
    CUDA_OK(cudaMemcpyToSymbol(g_cos, hcos.data(), SB_NDIR * 4));
    CUDA_OK(cudaMemcpyToSymbol(g_sin, hsin.data(), SB_NDIR * 4));

    float *d_grid, *d_scratch;
    unsigned *d_depcount, *d_arng;
    float *d_ax, *d_ay;
    unsigned short *d_adir;
    CUDA_OK(cudaMalloc(&d_grid, cells * 4));
    CUDA_OK(cudaMalloc(&d_scratch, cells * 4));
    CUDA_OK(cudaMalloc(&d_depcount, cells * 4));
    CUDA_OK(cudaMalloc(&d_ax, (size_t)o.agents * 4));
    CUDA_OK(cudaMalloc(&d_ay, (size_t)o.agents * 4));
    CUDA_OK(cudaMalloc(&d_adir, (size_t)o.agents * 2));
    CUDA_OK(cudaMalloc(&d_arng, (size_t)o.agents * 16));

    CUDA_OK(cudaMemcpy(d_grid, grid.data(), cells * 4, cudaMemcpyHostToDevice));
    CUDA_OK(cudaMemset(d_depcount, 0, cells * 4));
    CUDA_OK(cudaMemcpy(d_ax, ax.data(), (size_t)o.agents * 4, cudaMemcpyHostToDevice));
    CUDA_OK(cudaMemcpy(d_ay, ay.data(), (size_t)o.agents * 4, cudaMemcpyHostToDevice));
    CUDA_OK(cudaMemcpy(d_adir, adir.data(), (size_t)o.agents * 2, cudaMemcpyHostToDevice));
    CUDA_OK(cudaMemcpy(d_arng, arng.data(), (size_t)o.agents * 16, cudaMemcpyHostToDevice));

    const int tpb = 256;
    const int ab = (int)((o.agents + tpb - 1) / tpb);
    const int cb = (int)((cells + tpb - 1) / tpb);

    auto one_tick = [&]() {
        k_agents<<<ab, tpb>>>(d_grid, d_depcount, d_ax, d_ay, d_adir, d_arng);
        k_merge<<<cb, tpb>>>(d_grid, d_depcount, (unsigned)cells);
        k_diffuse<<<cb, tpb>>>(d_grid, d_scratch, (unsigned)cells);
        std::swap(d_grid, d_scratch);
    };

    for (unsigned t = 0; t < o.warmup; t++) one_tick();
    CUDA_OK(cudaDeviceSynchronize());

    std::vector<double> tick_ms;
    tick_ms.reserve(o.ticks);
    const double t_start = now_ms();
    for (unsigned t = 0; t < o.ticks; t++) {
        const double a = now_ms();
        one_tick();
        CUDA_OK(cudaDeviceSynchronize());
        tick_ms.push_back(now_ms() - a);
    }
    const double ms_total = now_ms() - t_start;
    CUDA_OK(cudaGetLastError());

    // ---- results ----------------------------------------------------------
    CUDA_OK(cudaMemcpy(grid.data(), d_grid, cells * 4, cudaMemcpyDeviceToHost));
    CUDA_OK(cudaMemcpy(ax.data(), d_ax, (size_t)o.agents * 4, cudaMemcpyDeviceToHost));
    CUDA_OK(cudaMemcpy(ay.data(), d_ay, (size_t)o.agents * 4, cudaMemcpyDeviceToHost));
    CUDA_OK(cudaMemcpy(adir.data(), d_adir, (size_t)o.agents * 2, cudaMemcpyDeviceToHost));

    unsigned gh = 0x811C9DC5u;
    for (size_t i = 0; i < cells; i++) {
        unsigned w; std::memcpy(&w, &grid[i], 4);
        gh = fnv(gh, w);
    }
    unsigned agh = 0x811C9DC5u;
    for (unsigned i = 0; i < o.agents; i++) {
        unsigned w;
        std::memcpy(&w, &ax[i], 4); agh = fnv(agh, w);
        std::memcpy(&w, &ay[i], 4); agh = fnv(agh, w);
        agh = fnv(agh, adir[i]);
    }
    unsigned dh = 0x811C9DC5u;
    for (int d = 0; d < SB_NDIR; d++) dh = fnv(dh, SB_COS_BITS[d]);
    for (int d = 0; d < SB_NDIR; d++) dh = fnv(dh, SB_SIN_BITS[d]);

    if (!o.dump_grid.empty()) {
        std::FILE *f = std::fopen(o.dump_grid.c_str(), "wb");
        if (f) { std::fwrite(grid.data(), 4, cells, f); std::fclose(f); }
    }

    const size_t n = tick_ms.size();
    std::vector<double> srt = tick_ms;
    std::sort(srt.begin(), srt.end());
    const double median = n ? srt[n / 2] : 0.0;
    const double p99 = n ? srt[std::min(n - 1, (size_t)(n * 0.99))] : 0.0;
    const double mean = n ? std::accumulate(tick_ms.begin(), tick_ms.end(), 0.0) / n : 0.0;

    cudaDeviceProp prop{};
    cudaGetDeviceProperties(&prop, 0);

    if (o.json) {
        std::printf("{\"schema\":1,\"impl\":\"cuda\",\"backend\":\"cuda\",\"class\":\"G\","
            "\"preset\":\"%s\",\"variant\":\"sm_%d%d\","
            "\"width\":%u,\"height\":%u,\"agents\":%u,\"ticks\":%zu,\"seed\":%u,"
            "\"update\":\"deferred\",\"threads\":%d,"
            "\"grid_hash\":\"0x%08X\",\"agent_hash\":\"0x%08X\",\"dirtable_hash\":\"0x%08X\","
            "\"ms_total\":%.4f,\"ms_agents\":0.0,\"ms_diffuse\":0.0,"
            "\"ms_per_tick_mean\":%.6f,\"ms_per_tick_median\":%.6f,\"ms_per_tick_p99\":%.6f,"
            "\"maups\":%.4f,\"mcups\":%.4f}\n",
            o.preset.c_str(), prop.major, prop.minor,
            o.width, o.height, o.agents, n, o.seed, prop.multiProcessorCount,
            gh, agh, dh, ms_total, mean, median, p99,
            ms_total > 0 ? (double)o.agents * n / ms_total / 1000.0 : 0.0,
            ms_total > 0 ? (double)cells * n / ms_total / 1000.0 : 0.0);
    } else {
        std::printf("%s %ux%u agents=%u ticks=%u update=deferred device=%s sm_%d%d\n",
                    o.preset.c_str(), o.width, o.height, o.agents, o.ticks,
                    prop.name, prop.major, prop.minor);
        std::printf("  grid_hash  0x%08X\n", gh);
        std::printf("  agent_hash 0x%08X\n", agh);
        std::printf("  total      %.2f ms  (%.4f ms/tick)\n",
                    ms_total, o.ticks ? ms_total / o.ticks : 0.0);
    }

    cudaFree(d_grid); cudaFree(d_scratch); cudaFree(d_depcount);
    cudaFree(d_ax); cudaFree(d_ay); cudaFree(d_adir); cudaFree(d_arng);
    return 0;
}
