// slimebench -- C++ + SDL2 frontend.
//
// One job per frame: convert the f32 grid to a greyscale texture and blit it.
// The raylib frontend does exactly the same work on the identical byte buffer,
// which is what makes the SDL2-vs-raylib comparison meaningful.

#include <SDL.h>

#include <cstdio>
#include <vector>

#include "cli.hpp"
#include "hud.hpp"
#include "render.hpp"

// SDL keycodes for printable ASCII are the ASCII value, so the shared table
// covers everything except the three keys that have no character.
static sb_action sdlAction(SDL_Keycode k) {
    switch (k) {
    case SDLK_ESCAPE: return SB_ACT_QUIT;
    case SDLK_TAB:    return SB_ACT_HUD;
    case SDLK_F1:     return SB_ACT_HELP;
    default:          return sb_hud_action_for_char(int(k));
    }
}

int main(int argc, char** argv) {
    sb::Config cfg;
    sb::CliOpts opt;
    if (sb::parseArgs(argc, argv, cfg, opt) != 0) return 2;
    if (cfg.ticks == 0) cfg.ticks = 0xFFFFFFFFu;

    sb::Sim sim(cfg);

    if (SDL_Init(SDL_INIT_VIDEO) != 0) {
        std::fprintf(stderr, "SDL_Init: %s\n", SDL_GetError());
        return 1;
    }

    SDL_Window* win = SDL_CreateWindow(
        "slimebench -- C++ / SDL2", SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
        int(cfg.width), int(cfg.height), SDL_WINDOW_SHOWN);
    SDL_Renderer* ren = SDL_CreateRenderer(win, -1, SDL_RENDERER_ACCELERATED);
    SDL_Texture* tex = SDL_CreateTexture(ren, SDL_PIXELFORMAT_ARGB8888,
                                         SDL_TEXTUREACCESS_STREAMING,
                                         int(cfg.width), int(cfg.height));
    if (!win || !ren || !tex) {
        std::fprintf(stderr, "SDL setup failed: %s\n", SDL_GetError());
        SDL_Quit();
        return 1;
    }

    std::vector<std::uint8_t> gray(std::size_t(cfg.width) * cfg.height);
    // sb_hud_apply toggles it through a pointer, so it cannot live in the
    // bool-typed CliOpts.
    int freeze_sim = opt.freeze_sim;
    sb::RenderStats stats;
    sb_hud hud;
    sb_hud_init(&hud, "c++ / sdl2", opt.want_hud);
    sb_hud_view view = sb::hudViewOf(sim);

    for (std::uint32_t t = 0; !hud.want_quit && t < cfg.ticks; ++t) {
        SDL_Event e;
        while (SDL_PollEvent(&e)) {
            if (e.type == SDL_QUIT) hud.want_quit = 1;
            if (e.type == SDL_KEYDOWN)
                sb_hud_apply(&hud, &view, &freeze_sim, &opt.display_max,
                             sdlAction(e.key.keysym.sym));
        }
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

        // Timed separately and subtracted below: the overlay is not part of
        // the grid -> texture -> screen path the class R number reports.
        const std::uint64_t h0 = sb::nowNs();
        sb_hud_draw(&hud, &view, gray.data(), opt.display_max);
        const std::uint64_t hud_ns = sb::nowNs() - h0;

        void* pixels = nullptr;
        int pitch = 0;
        SDL_LockTexture(tex, nullptr, &pixels, &pitch);
        for (std::uint32_t y = 0; y < cfg.height; ++y) {
            auto* row = reinterpret_cast<std::uint32_t*>(
                static_cast<std::uint8_t*>(pixels) + std::size_t(y) * pitch);
            const std::uint8_t* src = gray.data() + std::size_t(y) * cfg.width;
            for (std::uint32_t x = 0; x < cfg.width; ++x) {
                const std::uint32_t v = src[x];
                row[x] = 0xFF000000u | (v << 16) | (v << 8) | v;
            }
        }
        SDL_UnlockTexture(tex);

        SDL_RenderClear(ren);
        SDL_RenderCopy(ren, tex, nullptr, nullptr);
        SDL_RenderPresent(ren);
        const std::uint64_t frame_ns = sb::nowNs() - r0;
        stats.add(frame_ns - hud_ns);
        sb_hud_observe(&hud, sim_ms, double(frame_ns - hud_ns) / 1e6);

        stats.maybeRetitle([&](const char* title) { SDL_SetWindowTitle(win, title); },
                           "slimebench -- C++ / SDL2");
    }

    SDL_DestroyTexture(tex);
    SDL_DestroyRenderer(ren);
    SDL_DestroyWindow(win);
    SDL_Quit();

    if (opt.want_json) {
        std::string backend = std::string("sdl2") + sb_hud_json_suffix(&hud);
        stats.emitJson("cpp", backend.c_str(), sim);
    }
    return 0;
}
