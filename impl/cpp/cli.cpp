#include "cli.hpp"

#include "simd.hpp"

#include <algorithm>
#include <charconv>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <numeric>
#include <string_view>

namespace sb {
namespace {

bool applyPreset(Config& c, std::string_view name) {
    if (name == "tiny") {
        c.width = 512;  c.height = 512;  c.agents = 65536;   c.ticks = 1000;
    } else if (name == "small") {
        c.width = 1024; c.height = 1024; c.agents = 262144;  c.ticks = 1000;
    } else if (name == "medium") {
        c.width = 2048; c.height = 2048; c.agents = 1048576; c.ticks = 1000;
    } else if (name == "large") {
        c.width = 4096; c.height = 4096; c.agents = 4194304; c.ticks = 500;
    } else if (name == "huge") {
        c.width = 8192; c.height = 8192; c.agents = 16777216; c.ticks = 100;
    } else if (name == "browser") {
        c.width = 1024; c.height = 1024; c.agents = 262144;  c.ticks = 0;
    } else {
        return false;
    }
    c.preset = std::string(name);
    return true;
}

}  // namespace

void printUsage(std::FILE* f, const char* argv0) {
    std::fprintf(f,
        "usage: %s [options]   (slimebench %s)\n"
        "  --preset NAME        tiny|small|medium|large|huge|browser\n"
        "  --width N --height N powers of two\n"
        "  --agents N  --ticks N  --warmup N  --seed N\n"
        "  --update MODE        serial|deferred\n"
        "  --threads N          class P, requires --update deferred\n"
        "  --deposit-reduce M   private|binned  (SPEC-1 5.6)\n"
        "  --sensor-dist F  --sensor-steps N  --rot-steps N\n"
        "  --step F  --deposit F  --decay F\n"
        "  --headless  --render  --freeze-sim\n"
        "  --json  --hash-every N  --dump-grid PATH  --display-max F\n"
        "  -h, --help\n",
        argv0, kSpecVersion);
}

int parseArgs(int argc, char** argv, Config& cfg, CliOpts& opt) {
    cfg = Config{};
    opt = CliOpts{};

    auto need = [&](int i, const char* flag) -> const char* {
        if (i + 1 >= argc) {
            std::fprintf(stderr, "error: %s requires a value\n", flag);
            std::exit(2);
        }
        return argv[i + 1];
    };
    auto u32 = [](const char* s) {
        return static_cast<std::uint32_t>(std::strtoul(s, nullptr, 10));
    };

    for (int i = 1; i < argc; ++i) {
        const std::string_view a = argv[i];

        if (a == "-h" || a == "--help") {
            printUsage(stdout, argv[0]);
            std::exit(0);
        } else if (a == "--preset") {
            const char* v = need(i++, "--preset");
            if (!applyPreset(cfg, v)) {
                std::fprintf(stderr, "error: unknown preset '%s'\n", v);
                return 2;
            }
        }
        else if (a == "--width")        { cfg.width  = u32(need(i++, "--width"));  cfg.preset = "custom"; }
        else if (a == "--height")       { cfg.height = u32(need(i++, "--height")); cfg.preset = "custom"; }
        else if (a == "--agents")       { cfg.agents = u32(need(i++, "--agents")); cfg.preset = "custom"; }
        else if (a == "--ticks")        { cfg.ticks  = u32(need(i++, "--ticks")); }
        else if (a == "--warmup")       { cfg.warmup = u32(need(i++, "--warmup")); }
        else if (a == "--seed")         { cfg.seed   = u32(need(i++, "--seed")); }
        else if (a == "--threads")      { cfg.threads = u32(need(i++, "--threads")); }
        else if (a == "--hash-every")   { cfg.hash_every = u32(need(i++, "--hash-every")); }
        else if (a == "--sensor-steps") { cfg.sensor_steps = u32(need(i++, "--sensor-steps")); }
        else if (a == "--rot-steps")    { cfg.rot_steps = u32(need(i++, "--rot-steps")); }
        else if (a == "--sensor-dist")  { cfg.sensor_dist = std::strtof(need(i++, "--sensor-dist"), nullptr); }
        else if (a == "--step")         { cfg.step = std::strtof(need(i++, "--step"), nullptr); }
        else if (a == "--deposit")      { cfg.deposit = std::strtof(need(i++, "--deposit"), nullptr); }
        else if (a == "--decay")        { cfg.decay = std::strtof(need(i++, "--decay"), nullptr); }
        else if (a == "--display-max")  { opt.display_max = std::strtof(need(i++, "--display-max"), nullptr); }
        else if (a == "--dump-grid")    { opt.dump_grid = need(i++, "--dump-grid"); }
        else if (a == "--deposit-reduce") {
            const std::string_view m = need(i++, "--deposit-reduce");
            if (m == "private") cfg.reduce = Reduce::Private;
            else if (m == "binned") cfg.reduce = Reduce::Binned;
            else { std::fprintf(stderr, "error: --deposit-reduce must be private|binned\n"); return 2; }
        }
        else if (a == "--update") {
            const std::string_view m = need(i++, "--update");
            if (m == "serial") cfg.update = Update::Serial;
            else if (m == "deferred") cfg.update = Update::Deferred;
            else { std::fprintf(stderr, "error: --update must be serial|deferred\n"); return 2; }
        }
        else if (a == "--headless")   { opt.want_render = false; }
        else if (a == "--render")     { opt.want_render = true; }
        else if (a == "--json")       { opt.want_json = true; }
        else if (a == "--freeze-sim") { opt.freeze_sim = true; }
        else if (a == "--simd")       { cfg.simd = true; }
        else if (a == "--no-simd")    { cfg.simd = false; }
        else if (a == "--hud")        { opt.want_hud = 1; }
        else if (a == "--no-hud")     { opt.want_hud = 0; }
        else {
            // SPEC-1 section 10: never silently ignore an unknown flag.
            std::fprintf(stderr, "error: unknown argument '%s'\n", argv[i]);
            printUsage(stderr, argv[0]);
            return 2;
        }
    }
    if (opt.want_hud < 0) opt.want_hud = !opt.want_json;
    return 0;
}

void emitJson(const Sim& sim, const char* impl, const char* backend,
              const char* cls, double ms_total, std::span<const double> tick_ms) {
    double median = 0.0, p99 = 0.0, mean = 0.0;
    const std::size_t n = tick_ms.size();
    if (n > 0) {
        std::vector<double> sorted(tick_ms.begin(), tick_ms.end());
        std::sort(sorted.begin(), sorted.end());
        median = sorted[n / 2];
        p99 = sorted[std::min(n - 1, static_cast<std::size_t>(double(n) * 0.99))];
        mean = std::accumulate(tick_ms.begin(), tick_ms.end(), 0.0) / double(n);
    }

    const Config& c = sim.cfg();
    // Class P interleaves the phases across threads, so the per-phase split
    // the serial path reports would be meaningless; emit zero there.
    const bool parallel = c.threads > 1;
    // One field describing what actually ran: reduction strategy for class P,
    // and the vector ISA the diffusion pass was compiled for.
    std::string variant =
        parallel ? (c.reduce == Reduce::Binned ? "binned" : "private") : "scalar";
    if (c.simd) variant += std::string("+simd-") + simdName();
    const double cells = double(c.width) * double(c.height);
    const double maups = ms_total > 0 ? double(c.agents) * double(n) / ms_total / 1000.0 : 0.0;
    const double mcups = ms_total > 0 ? cells * double(n) / ms_total / 1000.0 : 0.0;

    std::printf("{\"schema\":1,"
        "\"impl\":\"%s\",\"backend\":\"%s\",\"class\":\"%s\",\"preset\":\"%s\","
        "\"width\":%u,\"height\":%u,\"agents\":%u,\"ticks\":%zu,\"seed\":%u,"
        "\"update\":\"%s\",\"threads\":%u,\"variant\":\"%s\","
        "\"grid_hash\":\"0x%08X\",\"agent_hash\":\"0x%08X\",\"dirtable_hash\":\"0x%08X\","
        "\"ms_total\":%.4f,\"ms_agents\":%.4f,\"ms_diffuse\":%.4f,"
        "\"ms_per_tick_mean\":%.6f,\"ms_per_tick_median\":%.6f,\"ms_per_tick_p99\":%.6f,"
        "\"maups\":%.4f,\"mcups\":%.4f}\n",
        impl, backend, cls, c.preset.c_str(),
        c.width, c.height, c.agents, n, c.seed,
        c.update == Update::Deferred ? "deferred" : "serial", c.threads,
        variant.c_str(),
        sim.hashGrid(), sim.hashAgents(), Sim::dirtableHash(),
        ms_total,
        parallel ? 0.0 : double(sim.ns_agents) / 1e6,
        parallel ? 0.0 : double(sim.ns_diffuse) / 1e6,
        mean, median, p99, maups, mcups);
}

bool dumpGrid(const Sim& sim, const std::string& path) {
    std::FILE* f = std::fopen(path.c_str(), "wb");
    if (!f) return false;
    const auto& g = sim.grid();
    const std::size_t n = std::fwrite(g.data(), sizeof(float), g.size(), f);
    std::fclose(f);
    return n == g.size();
}

}  // namespace sb
