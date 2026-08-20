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
#include "hud.hpp"
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
    sb_hud hud;
    sb_hud_init(&hud, "c++ / raylib", opt.want_hud);
    sb_hud_view view = sb::hudViewOf(sim);
    int freeze_sim = opt.freeze_sim;
    std::uint32_t t = 0;

    while (!WindowShouldClose() && !hud.want_quit && t < cfg.ticks) {
        // GetCharPressed drains the character queue; the three non-character
        // keys are polled separately.
        for (int ch = GetCharPressed(); ch != 0; ch = GetCharPressed())
            sb_hud_apply(&hud, &view, &freeze_sim, &opt.display_max,
                         sb_hud_action_for_char(ch));
        if (IsKeyPressed(KEY_ESCAPE))
            sb_hud_apply(&hud, &view, &freeze_sim, &opt.display_max, SB_ACT_QUIT);
        if (IsKeyPressed(KEY_TAB))
            sb_hud_apply(&hud, &view, &freeze_sim, &opt.display_max, SB_ACT_HUD);
        if (IsKeyPressed(KEY_F1))
            sb_hud_apply(&hud, &view, &freeze_sim, &opt.display_max, SB_ACT_HELP);

        sb::hudViewInto(view, sim);
        sb::hudService(hud, sim, view);

        const std::uint64_t s0 = sb::nowNs();
        if (!freeze_sim && (!hud.paused || hud.step_once)) {
            sim.tick();
            ++hud.tick;
            hud.step_once = 0;
        }
        const double sim_ms = double(sb::nowNs() - s0) / 1e6;

        const std::uint64_t r0 = sb::nowNs();
        sim.renderGray(gray.data(), opt.display_max);

        const std::uint64_t h0 = sb::nowNs();
        sb_hud_draw(&hud, &view, gray.data(), opt.display_max);
        const std::uint64_t hud_ns = sb::nowNs() - h0;

        UpdateTexture(tex, gray.data());

        BeginDrawing();
        ClearBackground(BLACK);
        DrawTexture(tex, 0, 0, WHITE);
        EndDrawing();
        const std::uint64_t frame_ns = sb::nowNs() - r0;
        stats.add(frame_ns - hud_ns);
        sb_hud_observe(&hud, sim_ms, double(frame_ns - hud_ns) / 1e6);

        stats.maybeRetitle([](const char* title) { SetWindowTitle(title); },
                           "slimebench -- C++ / raylib");
        ++t;
    }

    UnloadTexture(tex);
    CloseWindow();

    if (opt.want_json) {
        std::string backend = std::string("raylib") + sb_hud_json_suffix(&hud);
        stats.emitJson("cpp", backend.c_str(), sim);
    }
    return 0;
}
