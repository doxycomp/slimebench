// Shared CLI parsing and result reporting (SPEC-1 section 10).
#pragma once

#include <span>
#include <string>
#include <vector>

#include "sim.hpp"

namespace sb {

struct CliOpts {
    bool want_render = false;
    bool want_json = false;
    // Render benchmarks only: keep re-uploading the same grid so the
    // measurement is the upload path, not the simulation (SPEC-1 11.1).
    bool freeze_sim = false;
    std::string dump_grid;
    float display_max = 100.0f;
    // Overlay in the windowed frontends: on for a human, off under --json
    // because drawing it is work the class R number should not include.
    // -1 means "not asked for either way".
    int want_hud = -1;
};

// Returns 0 on success, 2 on a usage error (message already on stderr).
int parseArgs(int argc, char** argv, Config& cfg, CliOpts& opt);
void printUsage(std::FILE* f, const char* argv0);

void emitJson(const Sim& sim, const char* impl, const char* backend,
              const char* cls, double ms_total, std::span<const double> tick_ms);

bool dumpGrid(const Sim& sim, const std::string& path);

}  // namespace sb
