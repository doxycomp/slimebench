// The tick, the initialisation and the checksums declared in sim.hpp.
//
// sim.hpp carries the design and the three deliberate departures from
// idiomatic C++; this file is the arithmetic, where SPEC-1's binding
// summation order lives and where the static assertion below refuses to
// build on an x87 target.
#include "sim.hpp"
#include "agent.hpp"
#include "simd.hpp"

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

    if (cfg.agent_tile) {
        aid_.resize(cfg.agents);
        slot_.resize(cfg.agents);
        agentIdx_.resize(cfg.agents);
        sortKey_.resize(cfg.agents);
        sortF32_.resize(cfg.agents);
        sortU32_.resize(std::size_t{cfg.agents} * 4);
        sortU16_.resize(cfg.agents);
        for (std::uint32_t i = 0; i < cfg.agents; ++i) { aid_[i] = i; slot_[i] = i; }
    }

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

// A counting sort of the agent arrays into 8x8 tiles of the grid, so that
// three sensor reads of neighbouring agents land in neighbouring cache lines.
//
// The C reference explains the choice of tile size and the measurement behind
// it (impl/c/sb_core.c). This is the same algorithm; what it is worth in C++
// rather than C is the question the two rows answer.
namespace {
constexpr std::uint32_t kTileShift = 3;   // 8x8 cells
}

void Sim::agentSort() noexcept {
    const std::uint32_t n = cfg_.agents;
    const std::uint32_t xmask = cfg_.width - 1u;
    const std::uint32_t ymask = cfg_.height - 1u;
    const std::uint32_t tw = (cfg_.width + (1u << kTileShift) - 1u) >> kTileShift;
    const std::uint32_t th = (cfg_.height + (1u << kTileShift) - 1u) >> kTileShift;

    std::vector<std::uint32_t> count(static_cast<std::size_t>(tw) * th + 1u, 0u);
    for (std::uint32_t j = 0; j < n; ++j) {
        const std::uint32_t x = static_cast<std::uint32_t>(ax_[j]) & xmask;
        const std::uint32_t y = static_cast<std::uint32_t>(ay_[j]) & ymask;
        sortKey_[j] = (y >> kTileShift) * tw + (x >> kTileShift);
        ++count[sortKey_[j] + 1u];
    }
    for (std::size_t t = 1; t < count.size(); ++t) count[t] += count[t - 1u];

    // Stable: walking the agents in their current order keeps a re-sort cheap
    // when almost nothing has moved.
    for (std::uint32_t j = 0; j < n; ++j) {
        const std::uint32_t dst = count[sortKey_[j]]++;
        sortF32_[dst] = ax_[j];
        sortU16_[dst] = adir_[j];
        for (int w = 0; w < 4; ++w)
            sortU32_[static_cast<std::size_t>(dst) * 4 + w] =
                arng_[static_cast<std::size_t>(j) * 4 + w];
        sortKey_[j] = dst;                  // reused as the permutation
    }
    ax_.swap(sortF32_);
    adir_.swap(sortU16_);
    arng_.swap(sortU32_);
    for (std::uint32_t j = 0; j < n; ++j) sortF32_[sortKey_[j]] = ay_[j];
    ay_.swap(sortF32_);
    for (std::uint32_t j = 0; j < n; ++j) sortU32_[sortKey_[j]] = aid_[j];
    for (std::uint32_t j = 0; j < n; ++j) aid_[j] = sortU32_[j];
    for (std::uint32_t j = 0; j < n; ++j) slot_[aid_[j]] = j;
}

void Sim::agentPass() noexcept {
    const Ctx k = makeCtx();
    const float deposit = cfg_.deposit;
    float* target = (cfg_.update == Update::Deferred) ? dep_.data() : grid_.data();

    // With spatial ordering the step order is no longer the agent order, so
    // the deposits are buffered and applied afterwards in ascending *agent*
    // index -- the same order, and therefore the same floats, as the direct
    // loop below.
    if (!agentIdx_.empty()) {
        const std::uint32_t n = cfg_.agents;
        for (std::uint32_t j = 0; j < n; ++j)
            agentIdx_[aid_[j]] = agentStep(k, j);
        for (std::uint32_t i = 0; i < n; ++i) {
            const std::uint32_t idx = agentIdx_[i];
            target[idx] = target[idx] + deposit;
        }
        return;
    }

    for (std::uint32_t i = 0; i < cfg_.agents; ++i) {
        const std::uint32_t idx = agentStep(k, i);
        target[idx] = target[idx] + deposit;
    }
}

void Sim::diffuseRows(std::uint32_t y0, std::uint32_t y1) noexcept {
    const std::uint32_t w = cfg_.width;
    const std::uint32_t log2w = log2w_;
    const std::uint32_t xmask = xmask_;
    const std::uint32_t ymask = ymask_;
    const float decay = cfg_.decay;

    const float* __restrict src = grid_.data();
    float* __restrict dst = scratch_.data();

    for (std::uint32_t y = y0; y < y1; ++y) {
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
}

void Sim::diffusePass() noexcept {
    if (cfg_.simd) diffuseRowsSimd(*this, 0, cfg_.height);
    else diffuseRows(0, cfg_.height);
    swapBuffers();
}

void Sim::tick() {
    const std::uint64_t t0 = nowNs();
    // Re-sort inside the timed region, not beside it: the ordering is only
    // worth having if it pays for itself.
    if (cfg_.agent_tile && ticksDone_ % cfg_.agent_tile == 0) agentSort();
    ++ticksDone_;

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
    // In agent order, which is slot order only when the arrays have not been
    // spatially re-sorted. A checksum that changed with a performance flag
    // would defeat the point of having one.
    for (std::uint32_t a = 0; a < cfg_.agents; ++a) {
        const std::uint32_t i = slot_.empty() ? a : slot_[a];
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
