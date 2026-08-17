// slimebench -- explicitly vectorised diffusion pass (benchmark class V).
//
// Same kernel and the same reasoning as impl/c/sb_simd.h: element-wise, one
// output cell per lane, no cross-lane reduction, so it is conformance tier A
// rather than tier C. No FMA, and a real division by twelve.
//
// The agent pass stays scalar here too; see the C header for why.

#pragma once

#include <cstdint>

#include "sim.hpp"

namespace sb {

// false if this build has no vector path (kernel falls back to scalar).
bool simdAvailable() noexcept;
// Widest ISA compiled in: "avx512f", "avx2" or "scalar".
const char* simdName() noexcept;

// SPEC-1 section 5.4 over rows [y0, y1). Bit-identical to Sim::diffuseRows.
void diffuseRowsSimd(Sim& sim, std::uint32_t y0, std::uint32_t y1) noexcept;

}  // namespace sb
