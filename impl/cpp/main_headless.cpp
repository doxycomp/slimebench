// slimebench -- C++ headless benchmark frontend (class S).

#include <cstdio>
#include <memory>
#include <vector>

#include "cli.hpp"
#include "parallel.hpp"

int main(int argc, char** argv) {
    sb::Config cfg;
    sb::CliOpts opt;
    if (sb::parseArgs(argc, argv, cfg, opt) != 0) return 2;

    sb::Sim sim(cfg);

    std::unique_ptr<sb::Pool> pool;
    if (cfg.threads > 1) {
        pool = sb::Pool::create(sim);
        if (!pool) return 3;          // message already on stderr
    }
    const auto step = [&] { if (pool) pool->tick(); else sim.tick(); };

    for (std::uint32_t t = 0; t < cfg.warmup; ++t) step();
    sim.ns_agents = 0;
    sim.ns_diffuse = 0;

    std::vector<double> tick_ms;
    tick_ms.reserve(cfg.ticks);

    const std::uint64_t t_start = sb::nowNs();
    for (std::uint32_t t = 0; t < cfg.ticks; ++t) {
        const std::uint64_t a = sb::nowNs();
        step();
        tick_ms.push_back(double(sb::nowNs() - a) / 1e6);

        if (cfg.hash_every && ((t + 1) % cfg.hash_every == 0)) {
            std::fprintf(stderr, "tick %u grid=0x%08X agents=0x%08X\n",
                         t + 1, sim.hashGrid(), sim.hashAgents());
        }
    }
    const double ms_total = double(sb::nowNs() - t_start) / 1e6;

    if (!opt.dump_grid.empty() && !sb::dumpGrid(sim, opt.dump_grid)) {
        std::fprintf(stderr, "error: could not write %s\n", opt.dump_grid.c_str());
    }

    if (opt.want_json) {
        sb::emitJson(sim, "cpp", pool ? "std-thread" : "headless",
                     pool ? "P" : "S", ms_total, tick_ms);
    } else {
        std::printf("%s %ux%u agents=%u ticks=%u update=%s threads=%u%s\n",
                    cfg.preset.c_str(), cfg.width, cfg.height, cfg.agents, cfg.ticks,
                    cfg.update == sb::Update::Deferred ? "deferred" : "serial",
                    cfg.threads,
                    pool ? (cfg.reduce == sb::Reduce::Binned ? " reduce=binned"
                                                             : " reduce=private")
                         : "");
        std::printf("  grid_hash  0x%08X\n", sim.hashGrid());
        std::printf("  agent_hash 0x%08X\n", sim.hashAgents());
        std::printf("  total      %.2f ms  (%.4f ms/tick)\n",
                    ms_total, cfg.ticks ? ms_total / cfg.ticks : 0.0);
        std::printf("  agents     %.2f ms\n", double(sim.ns_agents) / 1e6);
        std::printf("  diffuse    %.2f ms\n", double(sim.ns_diffuse) / 1e6);
    }
    return 0;
}
