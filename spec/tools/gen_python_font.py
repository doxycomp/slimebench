"""Emit the Python font table from impl/c/sb_font.h.

The same argument as gen_rust_font.py: fifty-six glyphs transcribed by hand
into a third language is a way to introduce a typo that shows up as one wrong
pixel in an overlay nobody screenshots. The table is generated, and it carries
the same FNV-32 hash the C and Rust sides check, so an edit to one of the
three is caught the first time a window opens.
"""
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parents[2]
src = (ROOT / "impl/c/sb_font.h").read_text(encoding="utf-8")

chars = re.search(r'SB_FONT_CHARS\[\] =\s*\n\s*"(.*)";', src).group(1)
chars = chars.encode().decode("unicode_escape")

body = src[src.index("SB_FONT_ROWS[] = {"):src.index("/* Drawn for anything")]
glyphs, labels = [], []
for line in body.splitlines():
    m = re.match(r'\s*/\*(.*?)\*/\s*(".*")\s*,\s*$', line)
    if not m:
        continue
    labels.append(m.group(1).strip() or "space")
    g = "".join(re.findall(r'"([^"]*)"', m.group(2)))
    assert len(g) == 35, (m.group(1), len(g))
    glyphs.append(g)

assert len(glyphs) == len(chars), (len(glyphs), len(chars), chars)

missing = "".join(re.findall(
    r'"([^"]*)"',
    src[src.index("SB_GLYPH_MISSING[] ="):
        src.index("static inline const char *sb_font_glyph")]))
assert len(missing) == 35, len(missing)

h = 0x811C9DC5
for g in glyphs:
    for ch in g:
        h = ((h ^ ord(ch)) * 0x01000193) & 0xFFFFFFFF

out = ROOT / "impl/python/slimebench/font.py"
rows = "\n".join(f'    {g!r},  # {lab}' for g, lab in zip(glyphs, labels))
out.write_text(f'''"""The 5x7 bitmap font, generated from impl/c/sb_font.h.

Do not edit: run spec/tools/gen_python_font.py. CI re-runs every generator and
fails if the committed output differs.
"""

GLYPH_W = 5
GLYPH_H = 7

FONT_CHARS = {chars!r}

# One string of 35 characters per glyph, row-major, '#' set and '.' clear.
FONT = [
{rows}
]

MISSING = {missing!r}

# Same FNV-32 over the same bytes as sb_font_hash() in C and hud.rs in Rust.
FONT_HASH = 0x{h:08X}


def font_hash() -> int:
    h = 0x811C9DC5
    for g in FONT:
        for ch in g:
            h = ((h ^ ord(ch)) * 0x01000193) & 0xFFFFFFFF
    return h


def glyph(c: str) -> str:
    """The rows for one character, folded to upper case like the C side."""
    c = c.upper()
    i = FONT_CHARS.find(c)
    return FONT[i] if i >= 0 else MISSING


assert font_hash() == FONT_HASH, "glyph table changed; regenerate from sb_font.h"
assert len(FONT) == len(FONT_CHARS)
assert all(len(g) == GLYPH_W * GLYPH_H for g in FONT)
''', encoding="utf-8", newline="\n")
print(f"emitted {len(glyphs)} glyphs, FONT_HASH = 0x{h:08X}")
