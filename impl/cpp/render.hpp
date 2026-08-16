// Shared render-timing helper for the windowed frontends (SPEC-1 section 11.1).
//
// The point of a rendering backend benchmark is the upload path
// grid -> texture -> screen. If the simulation keeps running while you measure,
// it dominates the frame and SDL2 and raylib come out indistinguishable.
// So `--freeze-sim` stops the simulation and every frame re-uploads the same
// grid, which is exactly the work we want to compare.

#pragma once

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <numeric>
#include <vector>

#include "sim.hpp"

namespace sb {

class RenderStats {
  public:
    void add(std::uint64_t ns) {
        ns_.push_back(ns);
        ++since_title_;
    }

    // Refresh the window title roughly once a second without pulling in a
    // clock: 60 frames is close enough and costs nothing.
    template <typename SetTitle>
    void maybeRetitle(SetTitle set_title, const char* base) {
        if (since_title_ < 60) return;
        const double ms = recentMeanMs(60);
        char buf[160];
        std::snprintf(buf, sizeof buf, "%s -- %.2f ms/frame (%.0f fps)",
                      base, ms, ms > 0 ? 1000.0 / ms : 0.0);
        set_title(buf);
        since_title_ = 0;
    }

    void emitJson(const char* impl, const char* backend, const Sim& sim) const {
        if (ns_.empty()) return;
        std::vector<double> ms;
        ms.reserve(ns_.size());
        for (std::uint64_t v : ns_) ms.push_back(double(v) / 1e6);
        std::vector<double> sorted = ms;
        std::sort(sorted.begin(), sorted.end());

        const std::size_t n = sorted.size();
        const double mean = std::accumulate(ms.begin(), ms.end(), 0.0) / double(n);
        const double median = sorted[n / 2];
        const double p99 = sorted[std::min(n - 1, std::size_t(double(n) * 0.99))];
        const Config& c = sim.cfg();
        const double mpix = double(c.width) * double(c.height) / 1e6;

        std::printf("{\"schema\":1,\"impl\":\"%s\",\"backend\":\"%s\",\"class\":\"R\","
                    "\"preset\":\"%s\",\"width\":%u,\"height\":%u,\"frames\":%zu,"
                    "\"ms_render_mean\":%.6f,\"ms_render_median\":%.6f,"
                    "\"ms_render_p99\":%.6f,\"fps_equiv\":%.2f,\"mpixels_per_s\":%.1f}\n",
                    impl, backend, c.preset.c_str(), c.width, c.height, n,
                    mean, median, p99,
                    median > 0 ? 1000.0 / median : 0.0,
                    median > 0 ? mpix * 1000.0 / median : 0.0);
    }

  private:
    double recentMeanMs(std::size_t k) const {
        const std::size_t n = std::min(k, ns_.size());
        if (n == 0) return 0.0;
        double sum = 0.0;
        for (std::size_t i = ns_.size() - n; i < ns_.size(); ++i) sum += double(ns_[i]);
        return sum / double(n) / 1e6;
    }

    std::vector<std::uint64_t> ns_;
    std::size_t since_title_ = 0;
};

}  // namespace sb
