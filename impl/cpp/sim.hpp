// slimebench -- C++ implementation of SPEC-1.
//
// Deliberately idiomatic C++ (std::vector, std::array, std::bit_cast, RAII)
// rather than a transliteration of the C reference. If g++ and gcc do not
// produce the same performance from structurally identical algorithms, that
// difference is a finding worth having -- so the abstractions stay in.
//
// What is NOT idiomatic, on purpose:
//   - no std::mt19937: SPEC-1 mandates xoshiro128++ for cross-language equality
//   - no std::sinf: SPEC-1 section 4 mandates the generated table
//   - struct-of-arrays for agents, because the SIMD and GPU tiers will want it

#pragma once

#include <array>
#include <bit>
#include <cstdint>
#include <string>
#include <vector>

#include "dirtable.hpp"

namespace sb {

inline constexpr const char* kSpecVersion = "SPEC-1";

enum class Update { Serial, Deferred };

// SPEC-1 section 5.6. Private is reproducible per thread count; Binned is
// bit-identical to a single-threaded run for any thread count.
enum class Reduce { Private, Binned };

struct Config {
    std::uint32_t width = 1024;
    std::uint32_t height = 1024;
    std::uint32_t agents = 262144;
    std::uint32_t ticks = 1000;
    std::uint32_t warmup = 0;
    std::uint32_t seed = 12345;
    std::uint32_t threads = 1;
    Update update = Update::Serial;
    Reduce reduce = Reduce::Private;

    float sensor_dist = 9.0f;
    float step = 1.0f;
    float deposit = 10.0f;
    float decay = 0.94f;
    std::uint32_t sensor_steps = 144;
    std::uint32_t rot_steps = 144;

    std::uint32_t hash_every = 0;
    std::string preset = "custom";
};

// ---- PRNG (SPEC-1 section 3.1) ------------------------------------------

constexpr std::uint32_t rotl32(std::uint32_t x, int k) noexcept {
    return (x << k) | (x >> (32 - k));
}

constexpr std::uint32_t splitmix32(std::uint32_t& state) noexcept {
    state += 0x9E3779B9u;
    std::uint32_t z = state;
    z = (z ^ (z >> 16)) * 0x21F0AAADu;
    z = (z ^ (z >> 15)) * 0x735A2D97u;
    return z ^ (z >> 15);
}

constexpr std::uint32_t xoshiro128pp(std::uint32_t* s) noexcept {
    const std::uint32_t result = rotl32(s[0] + s[3], 7) + s[0];
    const std::uint32_t t = s[1] << 9;
    s[2] ^= s[0];
    s[3] ^= s[1];
    s[1] ^= s[2];
    s[0] ^= s[3];
    s[2] ^= t;
    s[3] = rotl32(s[3], 11);
    return result;
}

// SPEC-1 section 3.2. Exact: (u>>8) < 2^24, and 2^24 is a power of two.
constexpr float rnd01(std::uint32_t u) noexcept {
    return static_cast<float>(u >> 8) / 16777216.0f;
}

// ---- simulation ----------------------------------------------------------

class Sim {
  public:
    explicit Sim(const Config& cfg);

    void tick();

    std::uint32_t hashGrid() const noexcept;
    std::uint32_t hashAgents() const noexcept;
    static std::uint32_t dirtableHash() noexcept;

    // SPEC-1 section 11.
    void renderGray(std::uint8_t* out, float display_max) const noexcept;

    const Config& cfg() const noexcept { return cfg_; }
    const std::vector<float>& grid() const noexcept { return grid_; }

    // ---- used by the threaded tick (class P) ----------------------------
    //
    // Public rather than hidden behind a friend declaration: Pool needs the
    // same building blocks the serial path uses, and duplicating them so the
    // members could stay private is exactly the mistake that lets a parallel
    // implementation drift away from the rule it is supposed to follow.

    struct Ctx;                       // defined in agent.hpp
    Ctx makeCtx() const noexcept;
    // Advances agent `i`, returns the cell its deposit belongs in.
    std::uint32_t agentStep(const Ctx& k, std::uint32_t i) noexcept;
    // SPEC-1 section 5.4 for rows [y0, y1). Output cells are independent, so
    // splitting the range is unconditionally bit-identical.
    void diffuseRows(std::uint32_t y0, std::uint32_t y1) noexcept;
    void swapBuffers() noexcept { grid_.swap(scratch_); }

    std::vector<float>& gridMut() noexcept { return grid_; }
    std::vector<float>& dep() noexcept { return dep_; }
    std::uint32_t log2w() const noexcept { return log2w_; }

    std::uint64_t ns_agents = 0;
    std::uint64_t ns_diffuse = 0;

  private:
    void agentPass() noexcept;
    void diffusePass() noexcept;

    Config cfg_;
    std::uint32_t log2w_ = 0;
    std::uint32_t xmask_ = 0;
    std::uint32_t ymask_ = 0;

    std::vector<float> grid_;
    std::vector<float> scratch_;
    std::vector<float> dep_;

    std::vector<float> ax_;
    std::vector<float> ay_;
    std::vector<std::uint16_t> adir_;
    std::vector<std::uint32_t> arng_;

    std::array<float, kNdir> cos_{};
    std::array<float, kNdir> sin_{};
};

std::uint64_t nowNs() noexcept;

}  // namespace sb
