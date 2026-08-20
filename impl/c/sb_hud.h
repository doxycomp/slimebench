/* slimebench -- on-screen HUD and keyboard control for the windowed frontends.
 *
 * ## One overlay, drawn once
 *
 * Every windowed frontend already produces the same thing: the 8-bit
 * greyscale buffer from sb_render_gray(). The HUD is drawn into that buffer
 * before it is uploaded, so SDL2, raylib and the ports that reuse this pixel
 * path all get identical pixels from identical code, and adding a frontend
 * costs a key-mapping switch and nothing else.
 *
 * ## No modifier keys
 *
 * Parameters are bound to digit pairs (1/2 for deposit, 3/4 for decay, ...)
 * rather than to a letter plus shift. Shift state is reported differently by
 * SDL2, raylib, GLFW and the browser, and a control scheme that behaves
 * differently per frontend would undermine the point of sharing the overlay.
 *
 * ## Editing parameters costs reproducibility, and the HUD says so
 *
 * A key that changes deposit or decay puts the run off the SPEC-1 rails: the
 * hashes no longer correspond to any reproducible configuration. Rather than
 * forbid it -- watching the parameters move is most of why you would open a
 * window at all -- the HUD flags the run as EDITED from the first keypress,
 * and sb_hud_json_suffix() makes any JSON emitted afterwards say so too.
 *
 * ## Shared, not C-specific
 *
 * Nothing here knows what a sb_sim is. The HUD reads and writes a plain
 * sb_hud_view of scalars that the frontend fills from its own config and
 * copies back afterwards, so the C and C++ ports include this same file
 * rather than maintaining two drifting copies of a bitmap font.
 *
 * ## Timing
 *
 * Drawing the overlay is real work and would inflate the class R numbers, so
 * the frontends time it separately and subtract it. Under --json the HUD is
 * off unless asked for explicitly.
 */
#ifndef SB_HUD_H
#define SB_HUD_H

#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "sb_font.h"

/* ---- key actions -------------------------------------------------------- */

/* Frontends translate their own keycodes into these; nothing below this line
 * knows what SDL2 or raylib call a key. */
typedef enum {
    SB_ACT_NONE = 0,
    SB_ACT_QUIT,
    SB_ACT_PAUSE,
    SB_ACT_STEP,
    SB_ACT_RESET,
    SB_ACT_HUD,
    SB_ACT_HELP,
    SB_ACT_HASH,
    SB_ACT_FREEZE,
    SB_ACT_DEPOSIT_DN, SB_ACT_DEPOSIT_UP,
    SB_ACT_DECAY_DN,   SB_ACT_DECAY_UP,
    SB_ACT_SENSOR_DN,  SB_ACT_SENSOR_UP,
    SB_ACT_STEPLEN_DN, SB_ACT_STEPLEN_UP,
    SB_ACT_ROT_DN,     SB_ACT_ROT_UP,
    SB_ACT_BRIGHT_DN,  SB_ACT_BRIGHT_UP
} sb_action;

/* ASCII -> action, shared by every frontend. Special keys (Escape, Tab, F1)
 * have no ASCII form and are mapped by the frontend directly. */
static inline sb_action sb_hud_action_for_char(int c) {
    switch (c) {
    case 'q': case 'Q': return SB_ACT_QUIT;
    case ' ':           return SB_ACT_PAUSE;
    case 'n': case 'N': return SB_ACT_STEP;
    case 'r': case 'R': return SB_ACT_RESET;
    case 'h': case 'H': return SB_ACT_HELP;
    case 'c': case 'C': return SB_ACT_HASH;
    case 'f': case 'F': return SB_ACT_FREEZE;
    case '1': return SB_ACT_DEPOSIT_DN;  case '2': return SB_ACT_DEPOSIT_UP;
    case '3': return SB_ACT_DECAY_DN;    case '4': return SB_ACT_DECAY_UP;
    case '5': return SB_ACT_SENSOR_DN;   case '6': return SB_ACT_SENSOR_UP;
    case '7': return SB_ACT_STEPLEN_DN;  case '8': return SB_ACT_STEPLEN_UP;
    case '9': return SB_ACT_ROT_DN;      case '0': return SB_ACT_ROT_UP;
    case '-': case '_': return SB_ACT_BRIGHT_DN;
    case '=': case '+': return SB_ACT_BRIGHT_UP;
    default:  return SB_ACT_NONE;
    }
}

/* ---- state -------------------------------------------------------------- */

/* Everything the overlay shows or edits, as scalars. The frontend owns the
 * real config; this is the window onto it. */
typedef struct {
    uint32_t width, height, agents, threads, rot_steps, ndir;
    float deposit, decay, sensor_dist, step;
    int deferred;       /* SPEC-1 update mode, for display only */
} sb_hud_view;

typedef struct {
    int show_hud;
    int show_help;
    int paused;
    int step_once;      /* consumed by the frontend: run exactly one tick */
    int want_quit;
    int want_reset;     /* consumed by the frontend: it owns the sim object */
    int want_hash;      /* consumed by the frontend: only it can hash a grid */
    int edited;         /* a parameter was changed at runtime */
    uint32_t tick;
    double sim_ms;      /* exponentially smoothed, for a readable display */
    double render_ms;
    const char *label;  /* "C / SDL2" etc. */
} sb_hud;

static inline void sb_hud_init(sb_hud *h, const char *label, int show) {
    memset(h, 0, sizeof *h);
    h->show_hud = show;
    h->label = label;
    /* One line rather than an abort: a drifted glyph is a cosmetic bug, and
     * refusing to open a window over it would be worse than the bug. */
    const uint32_t fh = sb_font_hash();
    if (fh != SB_FONT_HASH)
        fprintf(stderr, "warning: font table is 0x%08X, expected 0x%08X -- "
                        "impl/rust/src/hud.rs needs regenerating\n",
                fh, SB_FONT_HASH);
}

/* A smoothing factor slow enough to read and fast enough to react. */
static inline void sb_hud_observe(sb_hud *h, double sim_ms, double render_ms) {
    const double a = 0.1;
    h->sim_ms = h->sim_ms == 0.0 ? sim_ms : h->sim_ms + a * (sim_ms - h->sim_ms);
    h->render_ms = h->render_ms == 0.0
                 ? render_ms : h->render_ms + a * (render_ms - h->render_ms);
}

static inline float sb_clampf(float v, float lo, float hi) {
    return v < lo ? lo : (v > hi ? hi : v);
}

/* Applies one action to the view. `display_max` is the frontend's brightness
 * scale; both may be NULL if the frontend has no such notion. */
static inline void sb_hud_apply(sb_hud *h, sb_hud_view *v, int *freeze_sim,
                                float *display_max, sb_action a) {
    int edit = 1;
    switch (a) {
    case SB_ACT_NONE:   return;
    case SB_ACT_QUIT:   h->want_quit = 1;                edit = 0; break;
    case SB_ACT_PAUSE:  h->paused = !h->paused;          edit = 0; break;
    case SB_ACT_STEP:   h->step_once = 1; h->paused = 1; edit = 0; break;
    case SB_ACT_RESET:  h->want_reset = 1;               edit = 0; break;
    case SB_ACT_HASH:   h->want_hash = 1;                edit = 0; break;
    case SB_ACT_HUD:    h->show_hud = !h->show_hud;      edit = 0; break;
    case SB_ACT_HELP:   h->show_help = !h->show_help;
                        if (h->show_help) h->show_hud = 1;
                        edit = 0; break;
    case SB_ACT_FREEZE: if (freeze_sim) *freeze_sim = !*freeze_sim;
                        edit = 0; break;

    /* Steps are multiplicative where the parameter spans orders of magnitude
     * and additive where it does not. */
    case SB_ACT_DEPOSIT_DN: v->deposit = sb_clampf(v->deposit / 1.25f, 0.001f, 1000.0f); break;
    case SB_ACT_DEPOSIT_UP: v->deposit = sb_clampf(v->deposit * 1.25f, 0.001f, 1000.0f); break;
    case SB_ACT_DECAY_DN:   v->decay   = sb_clampf(v->decay - 0.005f, 0.50f, 1.0f); break;
    case SB_ACT_DECAY_UP:   v->decay   = sb_clampf(v->decay + 0.005f, 0.50f, 1.0f); break;
    case SB_ACT_SENSOR_DN:  v->sensor_dist = sb_clampf(v->sensor_dist - 1.0f, 1.0f, 128.0f); break;
    case SB_ACT_SENSOR_UP:  v->sensor_dist = sb_clampf(v->sensor_dist + 1.0f, 1.0f, 128.0f); break;
    case SB_ACT_STEPLEN_DN: v->step    = sb_clampf(v->step - 0.1f, 0.1f, 16.0f); break;
    case SB_ACT_STEPLEN_UP: v->step    = sb_clampf(v->step + 0.1f, 0.1f, 16.0f); break;

    /* Direction indices are integers in [1, NDIR/4]; wrapping them would make
     * a fat-fingered keypress silently reverse the turn. */
    case SB_ACT_ROT_DN: if (v->rot_steps > 1u) v->rot_steps--; break;
    case SB_ACT_ROT_UP: if (v->rot_steps < v->ndir / 4u) v->rot_steps++; break;

    case SB_ACT_BRIGHT_DN: if (display_max) *display_max *= 1.25f; edit = 0; break;
    case SB_ACT_BRIGHT_UP: if (display_max) *display_max /= 1.25f; edit = 0; break;
    }
    if (edit) h->edited = 1;
}

/* Appended to the backend name in any JSON emitted after an edit, so an
 * interactively fiddled run can never be mistaken for a benchmark. */
static inline const char *sb_hud_json_suffix(const sb_hud *h) {
    return h->edited ? "+edited" : "";
}

/* ---- drawing ------------------------------------------------------------ */

/* Text is white on a darkened panel. Both are written straight into the
 * greyscale buffer: no blending machinery, no second surface. */
#define SB_HUD_FG 255

static inline void sb_hud_dim(uint8_t *g, uint32_t w, uint32_t h,
                              int x0, int y0, int x1, int y1) {
    if (x0 < 0) x0 = 0;
    if (y0 < 0) y0 = 0;
    if (x1 > (int)w) x1 = (int)w;
    if (y1 > (int)h) y1 = (int)h;
    for (int y = y0; y < y1; y++)
        for (int x = x0; x < x1; x++) {
            uint8_t *p = &g[(size_t)y * w + (size_t)x];
            *p = (uint8_t)(*p / 4u);
        }
}

static inline void sb_hud_text(uint8_t *g, uint32_t w, uint32_t h,
                               int px, int py, int scale, const char *str) {
    for (const char *c = str; *c; c++, px += (SB_GLYPH_W + 1) * scale) {
        if (*c == ' ') continue;
        const char *rows = sb_font_glyph(*c);
        for (int gy = 0; gy < SB_GLYPH_H; gy++)
            for (int gx = 0; gx < SB_GLYPH_W; gx++) {
                if (rows[gy * SB_GLYPH_W + gx] != '#') continue;
                for (int sy = 0; sy < scale; sy++)
                    for (int sx = 0; sx < scale; sx++) {
                        const int x = px + gx * scale + sx;
                        const int y = py + gy * scale + sy;
                        if (x < 0 || y < 0 || x >= (int)w || y >= (int)h) continue;
                        g[(size_t)y * w + (size_t)x] = SB_HUD_FG;
                    }
            }
    }
}

/* Scale so the overlay stays about the same physical size across presets:
 * roughly 90 characters across the window, clamped to something readable. */
static inline int sb_hud_scale(uint32_t w) {
    int s = (int)(w / 560u);
    if (s < 1) s = 1;
    if (s > 4) s = 4;
    return s;
}

static const char *const SB_HUD_HELP[] = {
    "KEYS",
    "  SPACE    PAUSE / RESUME",
    "  N        SINGLE STEP",
    "  R        RESET SIMULATION",
    "  TAB      HUD ON / OFF",
    "  H  F1    THIS HELP",
    "  C        PRINT HASHES TO STDERR",
    "  F        FREEZE SIM (RENDER ONLY)",
    "  1 / 2    DEPOSIT    DOWN / UP",
    "  3 / 4    DECAY      DOWN / UP",
    "  5 / 6    SENSOR     DOWN / UP",
    "  7 / 8    STEP       DOWN / UP",
    "  9 / 0    ROT STEPS  DOWN / UP",
    "  - / =    BRIGHTNESS DOWN / UP",
    "  Q  ESC   QUIT",
    "",
    "CHANGING A PARAMETER LEAVES THE SPEC-1",
    "CONFIGURATION. THE RUN IS THEN MARKED",
    "EDITED AND ITS HASHES REPRODUCE NOTHING.",
    NULL
};

/* Draws the overlay into the greyscale buffer. Call after sb_render_gray()
 * and before the upload. */
static inline void sb_hud_draw(const sb_hud *hud, const sb_hud_view *v,
                               uint8_t *g, float display_max) {
    if (!hud->show_hud) return;
    const uint32_t w = v->width, h = v->height;
    const int sc = sb_hud_scale(w);
    const int lh = (SB_GLYPH_H + 3) * sc;      /* line height */
    const int pad = 4 * sc;

    /* Lowercase format specifiers, lowercase text: sb_font_glyph() folds to
     * uppercase on lookup, so the HUD reads as caps without a second pass. */
    char line[5][96];
    snprintf(line[0], sizeof line[0], "slimebench  %s  %ux%u  %u agents",
             hud->label, w, h, v->agents);
    snprintf(line[1], sizeof line[1],
             "tick %u   sim %.2f ms   draw %.2f ms   %.0f fps",
             hud->tick, hud->sim_ms, hud->render_ms,
             (hud->sim_ms + hud->render_ms) > 0.0
                 ? 1000.0 / (hud->sim_ms + hud->render_ms) : 0.0);
    snprintf(line[2], sizeof line[2],
             "deposit %.3f  decay %.3f  sensor %.1f  step %.2f  rot %u",
             (double)v->deposit, (double)v->decay,
             (double)v->sensor_dist, (double)v->step, v->rot_steps);
    snprintf(line[3], sizeof line[3], "update %s  threads %u  bright %.0f",
             v->deferred ? "deferred" : "serial",
             v->threads, (double)display_max);
    snprintf(line[4], sizeof line[4], "%s%s   h for help",
             hud->paused ? "paused" : "running",
             hud->edited ? "   edited -- not reproducible" : "");

    const int nl = 5;
    int maxlen = 0;
    for (int i = 0; i < nl; i++) {
        const int n = (int)strlen(line[i]);
        if (n > maxlen) maxlen = n;
    }

    const int bw = maxlen * (SB_GLYPH_W + 1) * sc + 2 * pad;
    const int bh = nl * lh + 2 * pad;
    sb_hud_dim(g, w, h, 0, 0, bw, bh);
    for (int i = 0; i < nl; i++)
        sb_hud_text(g, w, h, pad, pad + i * lh, sc, line[i]);

    if (!hud->show_help) return;

    int hn = 0, hmax = 0;
    for (; SB_HUD_HELP[hn]; hn++) {
        const int n = (int)strlen(SB_HUD_HELP[hn]);
        if (n > hmax) hmax = n;
    }
    const int hx = pad;
    const int hy = bh + pad;
    /* Same width as the status panel, so the two read as one block. */
    int hw = hmax * (SB_GLYPH_W + 1) * sc + 2 * pad;
    if (hw < bw) hw = bw;
    sb_hud_dim(g, w, h, 0, hy - pad, hw, hy + hn * lh + pad);
    for (int i = 0; i < hn; i++)
        sb_hud_text(g, w, h, hx, hy + i * lh, sc, SB_HUD_HELP[i]);
}

#endif /* SB_HUD_H */
