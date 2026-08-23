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
#include "sb_hud_c.h"
#include "sb_render.h"

/* SDL keycodes for printable ASCII are the ASCII value, so the shared table
 * covers everything except the three keys that have no character. */
static sb_action sdl_action(SDL_Keycode k) {
    switch (k) {
    case SDLK_ESCAPE: return SB_ACT_QUIT;
    case SDLK_TAB:    return SB_ACT_HUD;
    case SDLK_F1:     return SB_ACT_HELP;
    default:          return sb_hud_action_for_char((int)k);
    }
}

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
        (int)cfg.width, (int)cfg.height,
        SDL_WINDOW_SHOWN | (opt.fullscreen
                            ? SDL_WINDOW_FULLSCREEN_DESKTOP : 0u));
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

    sb_render_stats stats;
    sb_rs_init(&stats, cfg.ticks == 0xFFFFFFFFu ? 100000 : cfg.ticks);
    sb_hud hud;
    sb_hud_init(&hud, "c / sdl2", opt.want_hud);
    sb_hud_view view = sb_hud_view_of(&sim);

    for (uint32_t t = 0; !hud.want_quit && t < cfg.ticks; t++) {
        SDL_Event e;
        while (SDL_PollEvent(&e)) {
            if (e.type == SDL_QUIT) hud.want_quit = 1;
            if (e.type == SDL_KEYDOWN)
                sb_hud_apply(&hud, &view, &opt.freeze_sim, &opt.display_max,
                             sdl_action(e.key.keysym.sym));
        }
        sb_hud_view_into(&view, &sim);
        if (!sb_hud_service(&hud, &sim, &view)) break;

        const uint64_t s0 = sb_now_ns();
        if (!opt.freeze_sim && (!hud.paused || hud.step_once)) {
            sb_tick(&sim);
            hud.tick++;
            hud.step_once = 0;
        }
        const double sim_ms = (double)(sb_now_ns() - s0) / 1e6;

        const uint64_t r0 = sb_now_ns();
        sb_render_gray(&sim, gray, opt.display_max);

        /* Timed separately and subtracted below: the overlay is not part of
         * the grid -> texture -> screen path the class R number reports. */
        const uint64_t h0 = sb_now_ns();
        sb_hud_draw(&hud, &view, gray, opt.display_max);
        const uint64_t hud_ns = sb_now_ns() - h0;

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
        const uint64_t frame_ns = sb_now_ns() - r0;
        sb_rs_add(&stats, frame_ns - hud_ns);
        sb_hud_observe(&hud, sim_ms, (double)(frame_ns - hud_ns) / 1e6);

        if (stats.since_title >= 60) {
            const double ms = sb_rs_recent_mean(&stats, 60);
            char title[160];
            snprintf(title, sizeof title,
                     "slimebench -- C / SDL2 -- %.2f ms/frame (%.0f fps)",
                     ms, ms > 0 ? 1000.0 / ms : 0.0);
            SDL_SetWindowTitle(win, title);
            stats.since_title = 0;
        }
    }

    if (opt.want_json) {
        char backend[32];
        snprintf(backend, sizeof backend, "sdl2%s", sb_hud_json_suffix(&hud));
        sb_rs_emit_json(&stats, &sim, "c", backend);
    }

    sb_rs_free(&stats);
    free(gray);
    SDL_DestroyTexture(tex);
    SDL_DestroyRenderer(ren);
    SDL_DestroyWindow(win);
    SDL_Quit();
    sb_sim_free(&sim);
    return 0;
}
