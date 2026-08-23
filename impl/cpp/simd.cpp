// The vectorised diffusion kernel declared in simd.hpp (class V).
//
// One kernel body, not two. `Vec` and the one-line `vload`/`vadd`/`vmul`
// helpers below are bound to __m512 or __m256 by #if at compile time, so
// the AVX2 and AVX-512 measurements in docs/RESULTS.md section 8 are the
// same source text at two widths rather than two hand-written kernels.
#include "simd.hpp"

#if defined(__AVX512F__) || defined(__AVX2__)
#include <immintrin.h>
#define SB_HAVE_SIMD 1
#else
#define SB_HAVE_SIMD 0
#endif

namespace sb {
namespace {

#if defined(__AVX512F__)
constexpr std::uint32_t kVW = 16;
using Vec = __m512;
inline Vec vload(const float* p) noexcept { return _mm512_loadu_ps(p); }
inline void vstore(float* p, Vec v) noexcept { _mm512_storeu_ps(p, v); }
inline Vec vset1(float x) noexcept { return _mm512_set1_ps(x); }
inline Vec vadd(Vec a, Vec b) noexcept { return _mm512_add_ps(a, b); }
inline Vec vmul(Vec a, Vec b) noexcept { return _mm512_mul_ps(a, b); }
inline Vec vdiv(Vec a, Vec b) noexcept { return _mm512_div_ps(a, b); }
constexpr const char* kName = "avx512f";
#elif defined(__AVX2__)
constexpr std::uint32_t kVW = 8;
using Vec = __m256;
inline Vec vload(const float* p) noexcept { return _mm256_loadu_ps(p); }
inline void vstore(float* p, Vec v) noexcept { _mm256_storeu_ps(p, v); }
inline Vec vset1(float x) noexcept { return _mm256_set1_ps(x); }
inline Vec vadd(Vec a, Vec b) noexcept { return _mm256_add_ps(a, b); }
inline Vec vmul(Vec a, Vec b) noexcept { return _mm256_mul_ps(a, b); }
inline Vec vdiv(Vec a, Vec b) noexcept { return _mm256_div_ps(a, b); }
constexpr const char* kName = "avx2";
#else
constexpr std::uint32_t kVW = 1;
constexpr const char* kName = "scalar";
#endif

#if SB_HAVE_SIMD
// One output cell, scalar. Used for the two wrapping columns, which the vector
// body cannot reach with plain unaligned loads.
inline void diffuseCell(const float* src, float* dst, std::uint32_t x,
                        std::uint32_t rowm, std::uint32_t row0,
                        std::uint32_t rowp, std::uint32_t xmask,
                        float decay) noexcept {
    const std::uint32_t xm = (x - 1u) & xmask;
    const std::uint32_t xp = (x + 1u) & xmask;

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
#endif

}  // namespace

bool simdAvailable() noexcept { return SB_HAVE_SIMD != 0; }
const char* simdName() noexcept { return kName; }

#if SB_HAVE_SIMD

void diffuseRowsSimd(Sim& sim, std::uint32_t y0, std::uint32_t y1) noexcept {
    const Config& c = sim.cfg();
    const std::uint32_t w = c.width;
    const std::uint32_t log2w = sim.log2w();
    const std::uint32_t xmask = w - 1u;
    const std::uint32_t ymask = c.height - 1u;
    const float decay = c.decay;

    // Narrow grids leave no vector body worth entering.
    if (w < 2 * kVW) {
        sim.diffuseRows(y0, y1);
        return;
    }

    const float* src = sim.gridMut().data();
    float* dst = sim.scratchMut().data();

    const Vec vfour = vset1(4.0f);
    const Vec vtwelve = vset1(12.0f);
    const Vec vdecay = vset1(decay);

    for (std::uint32_t y = y0; y < y1; ++y) {
        const std::uint32_t rowm = ((y - 1u) & ymask) << log2w;
        const std::uint32_t row0 = y << log2w;
        const std::uint32_t rowp = ((y + 1u) & ymask) << log2w;

        const float* pm = src + rowm;
        const float* p0 = src + row0;
        const float* pp = src + rowp;
        float* out = dst + row0;

        // Column 0 wraps to w-1 on the left.
        diffuseCell(src, dst, 0, rowm, row0, rowp, xmask, decay);

        // Vector body over the interior. Same nine terms, same order, one
        // output cell per lane.
        std::uint32_t x = 1;
        for (; x + kVW <= w - 1u; x += kVW) {
            Vec acc = vload(pm + x - 1);
            acc = vadd(acc, vload(pm + x));
            acc = vadd(acc, vload(pm + x + 1));
            acc = vadd(acc, vload(p0 + x - 1));
            acc = vadd(acc, vmul(vfour, vload(p0 + x)));
            acc = vadd(acc, vload(p0 + x + 1));
            acc = vadd(acc, vload(pp + x - 1));
            acc = vadd(acc, vload(pp + x));
            acc = vadd(acc, vload(pp + x + 1));
            vstore(out + x, vmul(vdiv(acc, vtwelve), vdecay));
        }

        // Remainder plus the wrapping last column.
        for (; x < w; ++x)
            diffuseCell(src, dst, x, rowm, row0, rowp, xmask, decay);
    }
}

#else  // no vector ISA compiled in

void diffuseRowsSimd(Sim& sim, std::uint32_t y0, std::uint32_t y1) noexcept {
    sim.diffuseRows(y0, y1);
}

#endif

}  // namespace sb
