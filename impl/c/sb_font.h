/* A 5x7 bitmap font, written out as pictures.
 *
 * The windowed frontends need to put text on screen. SDL_ttf and raylib's
 * font loader are two different dependencies producing two different
 * renderings, and neither is available to the Perl and Haskell frontends that
 * share this pixel path -- so the font is data in a header instead, and every
 * frontend draws identical pixels.
 *
 * Each glyph is seven rows of five characters, '#' set and '.' clear, stored
 * as one 35-character string. That is larger than a packed bitmap and slower
 * to draw, and both are irrelevant: a HUD is a few hundred glyphs a frame. The
 * gain is that a glyph is legible in the source, so a typo is visible rather
 * than latent.
 *
 * Uppercase only. Lowercase input is folded up on lookup, which halves the
 * table and gives the HUD a consistent look.
 */
#ifndef SB_FONT_H
#define SB_FONT_H

#include <stdint.h>

#define SB_GLYPH_W 5
#define SB_GLYPH_H 7

/* Lookup order. A character not in here draws as SB_GLYPH_MISSING. */
static const char SB_FONT_CHARS[] =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 .,:-+/%=()[]<>?!*#_|";

static const char *const SB_FONT_ROWS[] = {
/* A */ ".###." "#...#" "#...#" "#####" "#...#" "#...#" "#...#",
/* B */ "####." "#...#" "#...#" "####." "#...#" "#...#" "####.",
/* C */ ".###." "#...#" "#...." "#...." "#...." "#...#" ".###.",
/* D */ "####." "#...#" "#...#" "#...#" "#...#" "#...#" "####.",
/* E */ "#####" "#...." "#...." "####." "#...." "#...." "#####",
/* F */ "#####" "#...." "#...." "####." "#...." "#...." "#....",
/* G */ ".###." "#...#" "#...." "#.###" "#...#" "#...#" ".###.",
/* H */ "#...#" "#...#" "#...#" "#####" "#...#" "#...#" "#...#",
/* I */ ".###." "..#.." "..#.." "..#.." "..#.." "..#.." ".###.",
/* J */ "..###" "...#." "...#." "...#." "...#." "#..#." ".##..",
/* K */ "#...#" "#..#." "#.#.." "##..." "#.#.." "#..#." "#...#",
/* L */ "#...." "#...." "#...." "#...." "#...." "#...." "#####",
/* M */ "#...#" "##.##" "#.#.#" "#...#" "#...#" "#...#" "#...#",
/* N */ "#...#" "##..#" "#.#.#" "#..##" "#...#" "#...#" "#...#",
/* O */ ".###." "#...#" "#...#" "#...#" "#...#" "#...#" ".###.",
/* P */ "####." "#...#" "#...#" "####." "#...." "#...." "#....",
/* Q */ ".###." "#...#" "#...#" "#...#" "#.#.#" "#..#." ".##.#",
/* R */ "####." "#...#" "#...#" "####." "#.#.." "#..#." "#...#",
/* S */ ".####" "#...." "#...." ".###." "....#" "....#" "####.",
/* T */ "#####" "..#.." "..#.." "..#.." "..#.." "..#.." "..#..",
/* U */ "#...#" "#...#" "#...#" "#...#" "#...#" "#...#" ".###.",
/* V */ "#...#" "#...#" "#...#" "#...#" "#...#" ".#.#." "..#..",
/* W */ "#...#" "#...#" "#...#" "#...#" "#.#.#" "##.##" "#...#",
/* X */ "#...#" "#...#" ".#.#." "..#.." ".#.#." "#...#" "#...#",
/* Y */ "#...#" "#...#" ".#.#." "..#.." "..#.." "..#.." "..#..",
/* Z */ "#####" "....#" "...#." "..#.." ".#..." "#...." "#####",
/* 0 */ ".###." "#...#" "#..##" "#.#.#" "##..#" "#...#" ".###.",
/* 1 */ "..#.." ".##.." "..#.." "..#.." "..#.." "..#.." ".###.",
/* 2 */ ".###." "#...#" "....#" "...#." "..#.." ".#..." "#####",
/* 3 */ "#####" "...#." "..#.." "...#." "....#" "#...#" ".###.",
/* 4 */ "...#." "..##." ".#.#." "#..#." "#####" "...#." "...#.",
/* 5 */ "#####" "#...." "####." "....#" "....#" "#...#" ".###.",
/* 6 */ "..##." ".#..." "#...." "####." "#...#" "#...#" ".###.",
/* 7 */ "#####" "....#" "...#." "..#.." ".#..." ".#..." ".#...",
/* 8 */ ".###." "#...#" "#...#" ".###." "#...#" "#...#" ".###.",
/* 9 */ ".###." "#...#" "#...#" ".####" "....#" "...#." ".##..",
/*   */ "....." "....." "....." "....." "....." "....." ".....",
/* . */ "....." "....." "....." "....." "....." ".##.." ".##..",
/* , */ "....." "....." "....." "....." ".##.." ".##.." ".#...",
/* : */ "....." ".##.." ".##.." "....." ".##.." ".##.." ".....",
/* - */ "....." "....." "....." "#####" "....." "....." ".....",
/* + */ "....." "..#.." "..#.." "#####" "..#.." "..#.." ".....",
/* / */ "....#" "....#" "...#." "..#.." ".#..." "#...." "#....",
/* %% */"##..#" "##..#" "...#." "..#.." ".#..." "#..##" "#..##",
/* = */ "....." "....." "#####" "....." "#####" "....." ".....",
/* ( */ "..##." ".#..." "#...." "#...." "#...." ".#..." "..##.",
/* ) */ ".##.." "...#." "....#" "....#" "....#" "...#." ".##..",
/* [ */ ".###." ".#..." ".#..." ".#..." ".#..." ".#..." ".###.",
/* ] */ ".###." "...#." "...#." "...#." "...#." "...#." ".###.",
/* < */ "...#." "..#.." ".#..." "#...." ".#..." "..#.." "...#.",
/* > */ ".#..." "..#.." "...#." "....#" "...#." "..#.." ".#...",
/* ? */ ".###." "#...#" "....#" "...#." "..#.." "....." "..#..",
/* ! */ "..#.." "..#.." "..#.." "..#.." "..#.." "....." "..#..",
/* * */ "....." "#.#.#" ".###." "#####" ".###." "#.#.#" ".....",
/* # */ ".#.#." ".#.#." "#####" ".#.#." "#####" ".#.#." ".....",
/* _ */ "....." "....." "....." "....." "....." "....." "#####",
/* | */ "..#.." "..#.." "..#.." "..#.." "..#.." "..#.." "..#..",
};

/* Drawn for anything not in the table, so a missing glyph is visible. */
static const char SB_GLYPH_MISSING[] =
    "#####" "#...#" "#...#" "#...#" "#...#" "#...#" "#####";

/* FNV-1a over the glyph bytes. impl/rust/src/hud.rs carries a generated copy
 * of this table and the same constant; sb_hud_init() compares them at startup
 * so an edit on either side is caught the first time a window opens, rather
 * than as one wrong pixel in a HUD nobody screenshots. Regenerate the Rust
 * side with spec/tools/gen_rust_font.py after changing a glyph here. */
#define SB_FONT_HASH 0x6856D243u

static inline uint32_t sb_font_hash(void) {
    uint32_t h = 0x811C9DC5u;
    for (int i = 0; SB_FONT_CHARS[i]; i++)
        for (int j = 0; j < SB_GLYPH_W * SB_GLYPH_H; j++)
            h = (h ^ (uint32_t)(unsigned char)SB_FONT_ROWS[i][j]) * 0x01000193u;
    return h;
}

static inline const char *sb_font_glyph(char c) {
    if (c >= 'a' && c <= 'z') c = (char)(c - 'a' + 'A');
    for (int i = 0; SB_FONT_CHARS[i]; i++)
        if (SB_FONT_CHARS[i] == c) return SB_FONT_ROWS[i];
    return SB_GLYPH_MISSING;
}

#endif /* SB_FONT_H */
