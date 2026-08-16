#include "sim.hpp"

#include <cfloat>
#include <ctime>
#include <stdexcept>

// SPEC-1 section 1.2 rule 5: no extended intermediate precision.
#if defined(FLT_EVAL_METHOD) && FLT_EVAL_METHOD != 0
#error "FLT_EVAL_METHOD must be 0 (SSE math). x87 breaks bit-exactness."
#endif

namespace sb {
namespace {

constexpr std::uint32_t kFnvOffset = 0x811C9DC5u;
constexpr std::uint32_t kFnvPrime = 0x01000193u;

constexpr std::uint32_t fnvStep(std::uint32_t h, std::uint32_t word) noexcept {
    return (h ^ word) * kFnvPrime;
}

// SPEC-1 section 2.2.
inline float wrapf(float v, float m) noexcept {
    if (v < 0.0f) v = v + m;
    if (v >= m) v = v - m;
    return v;
}

std::uint32_t log2Exact(std::uint32_t v) noexcept {
    std::uint32_t n = 0;
    while ((1u << n) < v) ++n;
    return n;
}

}  // namespace

Sim::Sim(const Config& cfg) : cfg_(cfg) {
    if (cfg.width == 0 || (cfg.width & (cfg.width - 1)) != 0) {
        throw std::invalid_argument("width must be a power of two");
    }
    if (cfg.height == 0 || (cfg.height & (cfg.height - 1)) != 0) {
        throw std::invalid_argument("height must be a power of two");
    }

    log2w_ = log2Exact(cfg.width);
    xmask_ = cfg.width - 1u;
    ymask_ = cfg.height - 1u;

    for (std::uint32_t d = 0; d < kNdir; ++d) {
        cos_[d] = std::bit_cast<float>(kCosBits[d]);
        sin_[d] = std::bit_cast<float>(kSinBits[d]);
    }

    const std::size_t cells = std::size_t{cfg.width} * cfg.height;
    grid_.resize(cells);
    scratch_.resize(cells);
    if (cfg.update == Update::Deferred) dep_.assign(cells, 0.0f);

    ax_.resize(cfg.agents);
    ay_.resize(cfg.agents);
    adir_.resize(cfg.agents);
    arng_.resize(std::size_t{cfg.agents} * 4);

    // Grid init: its own SplitMix32 stream (SPEC-1 section 3.3).
    std::uint32_t sm = cfg.seed ^ 0x5BF03635u;
    for (std::size_t i = 0; i < cells; ++i) {
        grid_[i] = rnd01(splitmix32(sm)) * 100.0f;
    }

    // Agent init: one independent stream per agent, so this is order-free.
    const float fw = static_cast<float>(cfg.width);
    const float fh = static_cast<float>(cfg.height);
    for (std::uint32_t i = 0; i < cfg.agents; ++i) {
        std::uint32_t asm_ = cfg.seed + 0x9E3779B9u * (i + 1u);
        std::uint32_t* r = &arng_[std::size_t{i} * 4];
        r[0] = splitmix32(asm_);
        r[1] = splitmix32(asm_);
        r[2] = splitmix32(asm_);
        r[3] = splitmix32(asm_);
        if ((r[0] | r[1] | r[2] | r[3]) == 0u) r[0] = 1u;

        ax_[i] = rnd01(xoshiro128pp(r)) * fw;
        ay_[i] = rnd01(xoshiro128pp(r)) * fh;
        adir_[i] = static_cast<std::uint16_t>(xoshiro128pp(r) % kNdir);
    }
}

void Sim::agentPass() noexcept {
    const std::uint32_t xmask = xmask_;
    const std::uint32_t ymask = ymask_;
    const std::uint32_t log2w = log2w_;
    const float fw = static_cast<float>(cfg_.width);
    const float fh = static_cast<float>(cfg_.height);
    const float sdist = cfg_.sensor_dist;
    const float step = cfg_.step;
    const float deposit = cfg_.deposit;
    const int ss = static_cast<int>(cfg_.sensor_steps);
    const int rs = static_cast<int>(cfg_.rot_steps);
    const int ndir = static_cast<int>(kNdir);

    // No __restrict on grid/target: in Update::Serial they are the same buffer
    // by design (agents see deposits made earlier in the same tick), and
    // promising otherwise would let the compiler reorder the deposit store
    // against the sensor loads. The tables do not alias, so they keep it.
    const float* grid = grid_.data();
    float* target = (cfg_.update == Update::Deferred) ? dep_.data() : grid_.data();
    const float* __restrict cos_tab = cos_.data();
    const float* __restrict sin_tab = sin_.data();

    auto sense = [&](float x, float y, int d) noexcept -> float {
        const float sx = wrapf(x + cos_tab[d] * sdist, fw);
        const float sy = wrapf(y + sin_tab[d] * sdist, fh);
        return grid[((static_cast<std::uint32_t>(sy) & ymask) << log2w) |
                    (static_cast<std::uint32_t>(sx) & xmask)];
    };

    const std::uint32_t n = cfg_.agents;
    for (std::uint32_t i = 0; i < n; ++i) {
        int d = adir_[i];
        float x = ax_[i];
        float y = ay_[i];

        const int dl = (d - ss + ndir) % ndir;
        const int dr = (d + ss) % ndir;

        const float fl = sense(x, y, dl);
        const float fc = sense(x, y, d);
        const float fr = sense(x, y, dr);

        if (fc >= fl && fc >= fr) {
            // straight on
        } else if (fc < fl && fc < fr) {
            if (xoshiro128pp(&arng_[std::size_t{i} * 4]) & 1u)
                d = (d + rs) % ndir;
            else
                d = (d - rs + ndir) % ndir;
        } else if (fl > fr) {
            d = (d - rs + ndir) % ndir;
        } else {
            d = (d + rs) % ndir;
        }

        x = wrapf(x + cos_tab[d] * step, fw);
        y = wrapf(y + sin_tab[d] * step, fh);

        const std::uint32_t idx =
            ((static_cast<std::uint32_t>(y) & ymask) << log2w) |
            (static_cast<std::uint32_t>(x) & xmask);
        target[idx] = target[idx] + deposit;

        adir_[i] = static_cast<std::uint16_t>(d);
        ax_[i] = x;
        ay_[i] = y;
    }
}

void Sim::diffusePass() noexcept {
    const std::uint32_t w = cfg_.width;
    const std::uint32_t h = cfg_.height;
    const std::uint32_t log2w = log2w_;
    const std::uint32_t xmask = xmask_;
    const std::uint32_t ymask = ymask_;
    const float decay = cfg_.decay;

    const float* __restrict src = grid_.data();
    float* __restrict dst = scratch_.data();

    for (std::uint32_t y = 0; y < h; ++y) {
        const std::uint32_t rowm = ((y - 1u) & ymask) << log2w;
        const std::uint32_t row0 = y << log2w;
        const std::uint32_t rowp = ((y + 1u) & ymask) << log2w;

        for (std::uint32_t x = 0; x < w; ++x) {
            const std::uint32_t xm = (x - 1u) & xmask;
            const std::uint32_t xp = (x + 1u) & xmask;

            // Summation order is normative. Do not reorder, do not fuse.
            float acc = src[rowm | xm];
            acc = acc + src[rowm | x];
            acc = acc + src[rowm | xp];
            acc = acc + src[row0 | xm];
            acc = acc + 4.0f * src[row0 | x];
            acc = acc + src[row0 | xp];
            acc = acc + src[rowp | xm];
            acc = acc + src[rowp | x];
            acc = acc + src[rowp | xp];

            dst[row0 | x] = (acc / 12.0f) * decay;
        }
    }

    grid_.swap(scratch_);
}

void Sim::tick() {
    const std::uint64_t t0 = nowNs();
    agentPass();
    const std::uint64_t t1 = nowNs();

    if (cfg_.update == Update::Deferred) {
        const std::size_t cells = grid_.size();
        for (std::size_t i = 0; i < cells; ++i) {
            grid_[i] = grid_[i] + dep_[i];
            dep_[i] = 0.0f;
        }
    }

    diffusePass();
    const std::uint64_t t2 = nowNs();

    ns_agents += t1 - t0;
    ns_diffuse += t2 - t1;
}

std::uint32_t Sim::hashGrid() const noexcept {
    std::uint32_t h = kFnvOffset;
    for (float v : grid_) h = fnvStep(h, std::bit_cast<std::uint32_t>(v));
    return h;
}

std::uint32_t Sim::hashAgents() const noexcept {
    std::uint32_t h = kFnvOffset;
    for (std::uint32_t i = 0; i < cfg_.agents; ++i) {
        h = fnvStep(h, std::bit_cast<std::uint32_t>(ax_[i]));
        h = fnvStep(h, std::bit_cast<std::uint32_t>(ay_[i]));
        h = fnvStep(h, static_cast<std::uint32_t>(adir_[i]));
    }
    return h;
}

std::uint32_t Sim::dirtableHash() noexcept {
    std::uint32_t h = kFnvOffset;
    for (std::uint32_t b : kCosBits) h = fnvStep(h, b);
    for (std::uint32_t b : kSinBits) h = fnvStep(h, b);
    return h;
}

void Sim::renderGray(std::uint8_t* out, float display_max) const noexcept {
    const float scale = 255.0f / display_max;
    const std::size_t cells = grid_.size();
    for (std::size_t i = 0; i < cells; ++i) {
        int v = static_cast<int>(grid_[i] * scale);
        if (v < 0) v = 0;
        if (v > 255) v = 255;
        out[i] = static_cast<std::uint8_t>(v);
    }
}

std::uint64_t nowNs() noexcept {
    timespec ts{};
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return static_cast<std::uint64_t>(ts.tv_sec) * 1000000000ull +
           static_cast<std::uint64_t>(ts.tv_nsec);
}

}  // namespace sb
