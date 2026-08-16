// The per-agent step of SPEC-1 section 5.3, shared by the serial and the
// multi-threaded tick.
//
// Like the C version it returns the target cell rather than depositing: the
// three callers put the deposit in three different places (the grid itself, a
// thread-private buffer, or an index array for later binning). One copy of the
// simulation rule is the only way the parallel path can be trusted.

#pragma once

#include <cstdint>

#include "sim.hpp"

namespace sb {

// Grid geometry hoisted out of the hot loop.
struct Sim::Ctx {
    const float* grid;
    const float* cos_tab;
    const float* sin_tab;
    float fw, fh, sdist, step;
    std::uint32_t xmask, ymask, log2w;
    int ss, rs;
};

// SPEC-1 section 2.2.
inline float wrapf(float v, float m) noexcept {
    if (v < 0.0f) v = v + m;
    if (v >= m) v = v - m;
    return v;
}

inline float sense(const Sim::Ctx& k, float x, float y, int d) noexcept {
    const float sx = wrapf(x + k.cos_tab[d] * k.sdist, k.fw);
    const float sy = wrapf(y + k.sin_tab[d] * k.sdist, k.fh);
    return k.grid[((static_cast<std::uint32_t>(sy) & k.ymask) << k.log2w) |
                  (static_cast<std::uint32_t>(sx) & k.xmask)];
}

inline Sim::Ctx Sim::makeCtx() const noexcept {
    return Ctx{
        grid_.data(), cos_.data(), sin_.data(),
        static_cast<float>(cfg_.width), static_cast<float>(cfg_.height),
        cfg_.sensor_dist, cfg_.step,
        xmask_, ymask_, log2w_,
        static_cast<int>(cfg_.sensor_steps), static_cast<int>(cfg_.rot_steps),
    };
}

inline std::uint32_t Sim::agentStep(const Ctx& k, std::uint32_t i) noexcept {
    constexpr int ndir = static_cast<int>(kNdir);
    int d = adir_[i];
    float x = ax_[i];
    float y = ay_[i];

    const int dl = (d - k.ss + ndir) % ndir;
    const int dr = (d + k.ss) % ndir;

    const float fl = sense(k, x, y, dl);
    const float fc = sense(k, x, y, d);
    const float fr = sense(k, x, y, dr);

    if (fc >= fl && fc >= fr) {
        // straight on
    } else if (fc < fl && fc < fr) {
        if (xoshiro128pp(&arng_[std::size_t{i} * 4]) & 1u)
            d = (d + k.rs) % ndir;
        else
            d = (d - k.rs + ndir) % ndir;
    } else if (fl > fr) {
        d = (d - k.rs + ndir) % ndir;
    } else {
        d = (d + k.rs) % ndir;
    }

    x = wrapf(x + k.cos_tab[d] * k.step, k.fw);
    y = wrapf(y + k.sin_tab[d] * k.step, k.fh);

    adir_[i] = static_cast<std::uint16_t>(d);
    ax_[i] = x;
    ay_[i] = y;

    return ((static_cast<std::uint32_t>(y) & k.ymask) << k.log2w) |
           (static_cast<std::uint32_t>(x) & k.xmask);
}

}  // namespace sb
