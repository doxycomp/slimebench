// slimebench -- C++ + SDL2 frontend.
//
// One job per frame: convert the f32 grid to a greyscale texture and blit it.
// The raylib frontend does exactly the same work on the identical byte buffer,
// which is what makes the SDL2-vs-raylib comparison meaningful.

#include <SDL.h>

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
    sb::RenderStats stats;
    bool running = true;

    for (std::uint32_t t = 0; running && t < cfg.ticks; ++t) {
        SDL_Event e;
        while (SDL_PollEvent(&e)) {
            if (e.type == SDL_QUIT) running = false;
            if (e.type == SDL_KEYDOWN &&
                (e.key.keysym.sym == SDLK_ESCAPE || e.key.keysym.sym == SDLK_q))
                running = false;
        }

        if (!opt.freeze_sim) sim.tick();

        const std::uint64_t r0 = sb::nowNs();
        sim.renderGray(gray.data(), opt.display_max);

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
        stats.add(sb::nowNs() - r0);

        stats.maybeRetitle([&](const char* title) { SDL_SetWindowTitle(win, title); },
                           "slimebench -- C++ / SDL2");
    }

    SDL_DestroyTexture(tex);
    SDL_DestroyRenderer(ren);
    SDL_DestroyWindow(win);
    SDL_Quit();

    if (opt.want_json) stats.emitJson("cpp", "sdl2", sim);
    return 0;
}
