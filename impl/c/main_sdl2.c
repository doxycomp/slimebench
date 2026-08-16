/* slimebench -- C + SDL2 frontend.
 *
 * The renderer does exactly one thing per frame: convert the f32 grid to a
 * greyscale texture and blit it. That is the fair way to compare SDL2 against
 * raylib later -- both get handed the identical byte buffer.
 */

#include <SDL.h>
#include <stdio.h>
#include <stdlib.h>

#include "sb_cli.h"

int main(int argc, char **argv) {
    sb_config cfg;
    sb_cli_opts opt;
    if (sb_parse_args(argc, argv, &cfg, &opt) != 0) return 2;
    if (cfg.ticks == 0) cfg.ticks = 0xFFFFFFFFu; /* browser preset: run forever */

    sb_sim sim;
    if (sb_sim_init(&sim, &cfg) != 0) {
        fprintf(stderr, "error: init failed\n");
        return 1;
    }

    if (SDL_Init(SDL_INIT_VIDEO) != 0) {
        fprintf(stderr, "SDL_Init: %s\n", SDL_GetError());
        sb_sim_free(&sim);
        return 1;
    }

    SDL_Window *win = SDL_CreateWindow(
        "slimebench -- C / SDL2", SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
        (int)cfg.width, (int)cfg.height, SDL_WINDOW_SHOWN);
    SDL_Renderer *ren = SDL_CreateRenderer(win, -1, SDL_RENDERER_ACCELERATED);
    SDL_Texture *tex = SDL_CreateTexture(ren, SDL_PIXELFORMAT_ARGB8888,
                                         SDL_TEXTUREACCESS_STREAMING,
                                         (int)cfg.width, (int)cfg.height);
    if (!win || !ren || !tex) {
        fprintf(stderr, "SDL setup failed: %s\n", SDL_GetError());
        SDL_Quit();
        sb_sim_free(&sim);
        return 1;
    }

    const size_t cells = (size_t)cfg.width * cfg.height;
    uint8_t *gray = (uint8_t *)malloc(cells);

    uint32_t frames = 0;
    uint64_t fps_t0 = sb_now_ns();
    int running = 1;

    for (uint32_t t = 0; running && t < cfg.ticks; t++) {
        SDL_Event e;
        while (SDL_PollEvent(&e)) {
            if (e.type == SDL_QUIT) running = 0;
            if (e.type == SDL_KEYDOWN &&
                (e.key.keysym.sym == SDLK_ESCAPE || e.key.keysym.sym == SDLK_q))
                running = 0;
        }

        sb_tick(&sim);
        sb_render_gray(&sim, gray, opt.display_max);

        void *pixels = NULL;
        int pitch = 0;
        SDL_LockTexture(tex, NULL, &pixels, &pitch);
        for (uint32_t y = 0; y < cfg.height; y++) {
            uint32_t *row = (uint32_t *)((uint8_t *)pixels + (size_t)y * pitch);
            const uint8_t *src = gray + (size_t)y * cfg.width;
            for (uint32_t x = 0; x < cfg.width; x++) {
                const uint32_t v = src[x];
                row[x] = 0xFF000000u | (v << 16) | (v << 8) | v;
            }
        }
        SDL_UnlockTexture(tex);

        SDL_RenderClear(ren);
        SDL_RenderCopy(ren, tex, NULL, NULL);
        SDL_RenderPresent(ren);

        if (++frames == 60) {
            const uint64_t now = sb_now_ns();
            const double fps = 60.0 * 1e9 / (double)(now - fps_t0);
            char title[128];
            snprintf(title, sizeof title, "slimebench -- C / SDL2 -- %.1f fps", fps);
            SDL_SetWindowTitle(win, title);
            frames = 0;
            fps_t0 = now;
        }
    }

    free(gray);
    SDL_DestroyTexture(tex);
    SDL_DestroyRenderer(ren);
    SDL_DestroyWindow(win);
    SDL_Quit();
    sb_sim_free(&sim);
    return 0;
}
