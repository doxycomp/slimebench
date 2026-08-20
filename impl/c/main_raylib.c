/* slimebench -- C + raylib frontend.
 *
 * Same work as main_sdl2.c on the identical byte buffer. The one substantive
 * difference is the pixel format: raylib's UNCOMPRESSED_GRAYSCALE takes the
 * 8-bit buffer from sb_render_gray directly, while SDL2 needs ARGB8888 and
 * therefore an expansion loop. That asymmetry is left in rather than
 * equalised -- it is how you would actually write each one, and it turns out
 * to be most of the difference between them.
 */

#include <raylib.h>
#include <stdio.h>
#include <stdlib.h>

#include "sb_cli.h"
#include "sb_hud_c.h"
#include "sb_render.h"

int main(int argc, char **argv) {
    sb_config cfg;
    sb_cli_opts opt;
    if (sb_parse_args(argc, argv, &cfg, &opt) != 0) return 2;
    if (cfg.ticks == 0) cfg.ticks = 0xFFFFFFFFu;

    sb_sim sim;
    if (sb_sim_init(&sim, &cfg) != 0) {
        fprintf(stderr, "error: init failed\n");
        return 1;
    }

    SetTraceLogLevel(LOG_WARNING);
    InitWindow((int)cfg.width, (int)cfg.height, "slimebench -- C / raylib");
    /* raylib closes the window on Escape by default; the HUD wants to see the
     * key so that quitting goes through the same path in both frontends. */
    SetExitKey(KEY_NULL);

    const size_t cells = (size_t)cfg.width * cfg.height;
    uint8_t *gray = (uint8_t *)malloc(cells);

    Image img = {0};
    img.data = gray;
    img.width = (int)cfg.width;
    img.height = (int)cfg.height;
    img.mipmaps = 1;
    img.format = PIXELFORMAT_UNCOMPRESSED_GRAYSCALE;
    Texture2D tex = LoadTextureFromImage(img);

    sb_render_stats stats;
    sb_rs_init(&stats, cfg.ticks == 0xFFFFFFFFu ? 100000 : cfg.ticks);
    sb_hud hud;
    sb_hud_init(&hud, "c / raylib", opt.want_hud);
    sb_hud_view view = sb_hud_view_of(&sim);

    for (uint32_t t = 0; t < cfg.ticks && !hud.want_quit && !WindowShouldClose();
         t++) {
        /* GetCharPressed drains the character queue; the three non-character
         * keys are polled separately. */
        for (int ch = GetCharPressed(); ch != 0; ch = GetCharPressed())
            sb_hud_apply(&hud, &view, &opt.freeze_sim, &opt.display_max,
                         sb_hud_action_for_char(ch));
        if (IsKeyPressed(KEY_ESCAPE))
            sb_hud_apply(&hud, &view, &opt.freeze_sim, &opt.display_max, SB_ACT_QUIT);
        if (IsKeyPressed(KEY_TAB))
            sb_hud_apply(&hud, &view, &opt.freeze_sim, &opt.display_max, SB_ACT_HUD);
        if (IsKeyPressed(KEY_F1))
            sb_hud_apply(&hud, &view, &opt.freeze_sim, &opt.display_max, SB_ACT_HELP);

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

        const uint64_t h0 = sb_now_ns();
        sb_hud_draw(&hud, &view, gray, opt.display_max);
        const uint64_t hud_ns = sb_now_ns() - h0;

        UpdateTexture(tex, gray);

        BeginDrawing();
        ClearBackground(BLACK);
        DrawTexture(tex, 0, 0, WHITE);
        EndDrawing();
        const uint64_t frame_ns = sb_now_ns() - r0;
        sb_rs_add(&stats, frame_ns - hud_ns);
        sb_hud_observe(&hud, sim_ms, (double)(frame_ns - hud_ns) / 1e6);

        if (stats.since_title >= 60) {
            const double ms = sb_rs_recent_mean(&stats, 60);
            char title[160];
            snprintf(title, sizeof title,
                     "slimebench -- C / raylib -- %.2f ms/frame (%.0f fps)",
                     ms, ms > 0 ? 1000.0 / ms : 0.0);
            SetWindowTitle(title);
            stats.since_title = 0;
        }
    }

    UnloadTexture(tex);
    CloseWindow();

    if (opt.want_json) {
        char backend[32];
        snprintf(backend, sizeof backend, "raylib%s", sb_hud_json_suffix(&hud));
        sb_rs_emit_json(&stats, &sim, "c", backend);
    }

    sb_rs_free(&stats);
    free(gray);
    sb_sim_free(&sim);
    return 0;
}
