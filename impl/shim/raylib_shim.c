/* By-value shims for the raylib frontends that cannot pass structs by value.
 *
 * raylib takes Image, Texture2D and Color by value. Two of the bindings in
 * this repo cannot express that:
 *
 *   * Haskell's `foreign import ccall` marshals scalars and pointers only.
 *   * Perl's FFI::Platypus passes records by pointer.
 *
 * So the five calls that need it get a one-line wrapper here, and both
 * frontends bind these instead. Everything else they use (InitWindow,
 * BeginDrawing, ...) takes scalars and is bound directly.
 *
 * Both link the same /usr/local/lib/libraylib.so the C, Rust and Python
 * frontends use. That is deliberate: h-raylib and the various Perl raylib
 * distributions vendor and rebuild raylib, and comparing a language against a
 * *different build* of the library would measure the wrong thing.
 */

#include <raylib.h>

static Color sb_unpack(unsigned int c) {
    Color out;
    out.r = (unsigned char)(c & 0xFF);
    out.g = (unsigned char)((c >> 8) & 0xFF);
    out.b = (unsigned char)((c >> 16) & 0xFF);
    out.a = (unsigned char)((c >> 24) & 0xFF);
    return out;
}

void sb_rl_load_texture(const Image *img, Texture2D *out) {
    *out = LoadTextureFromImage(*img);
}

void sb_rl_update_texture(const Texture2D *tex, const void *pixels) {
    UpdateTexture(*tex, pixels);
}

void sb_rl_draw_texture(const Texture2D *tex, int x, int y, unsigned int tint) {
    DrawTexture(*tex, x, y, sb_unpack(tint));
}

void sb_rl_unload_texture(const Texture2D *tex) {
    UnloadTexture(*tex);
}

void sb_rl_clear_background(unsigned int colour) {
    ClearBackground(sb_unpack(colour));
}

/* Size and alignment of the two structs, so the Haskell Storable instances
 * are checked against the header rather than guessed from it. */
int sb_rl_sizeof_image(void)   { return (int)sizeof(Image); }
int sb_rl_sizeof_texture(void) { return (int)sizeof(Texture2D); }
