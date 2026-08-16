// slimebench -- C++ + raylib frontend.
//
// Same work as main_sdl2.cpp, same byte buffer, same measurement points.
// The one substantive difference is the pixel format: raylib's
// UNCOMPRESSED_GRAYSCALE takes the 8-bit buffer straight from sb::renderGray
// with no expansion to RGBA, whereas SDL2 needs ARGB8888. That is exactly the
// kind of asymmetry the comparison is meant to expose, so it is left in place
// rather than equalised -- it is how you would actually write each one.

#include <raylib.h>

#include <cstdio>
#include <vector>

#include "cli.hpp"
#include "render.hpp"

int main(int argc, char** argv) {
    sb::Config cfg;
    sb::CliOpts opt;
    if (sb::parseArgs(argc, argv, cfg, opt) != 0) return 2;
    if (cfg.ticks == 0) cfg.ticks = 0xFFFFFFFFu;

    sb::Sim sim(cfg);

    SetTraceLogLevel(LOG_WARNING);
    SetConfigFlags(FLAG_VSYNC_HINT * 0);  // vsync off: we are measuring, not displaying
    InitWindow(int(cfg.width), int(cfg.height), "slimebench -- C++ / raylib");

    Image img = {
        .data = nullptr,
        .width = int(cfg.width),
        .height = int(cfg.height),
        .mipmaps = 1,
        .format = PIXELFORMAT_UNCOMPRESSED_GRAYSCALE,
    };
    std::vector<std::uint8_t> gray(std::size_t(cfg.width) * cfg.height);
    img.data = gray.data();
    Texture2D tex = LoadTextureFromImage(img);

    sb::RenderStats stats;
    std::uint32_t t = 0;

    while (!WindowShouldClose() && t < cfg.ticks) {
        if (!opt.freeze_sim) sim.tick();

        const std::uint64_t r0 = sb::nowNs();
        sim.renderGray(gray.data(), opt.display_max);
        UpdateTexture(tex, gray.data());

        BeginDrawing();
        ClearBackground(BLACK);
        DrawTexture(tex, 0, 0, WHITE);
        EndDrawing();
        stats.add(sb::nowNs() - r0);

        stats.maybeRetitle([](const char* title) { SetWindowTitle(title); },
                           "slimebench -- C++ / raylib");
        ++t;
    }

    UnloadTexture(tex);
    CloseWindow();

    if (opt.want_json) stats.emitJson("cpp", "raylib", sim);
    return 0;
}
