"""Emit the Rust font table from impl/c/sb_font.h.

Transcribing 56 glyphs by hand into a second language is a way to introduce a
typo that only shows up as one wrong pixel. The table is generated instead,
and hud.rs carries a test that hashes it against the same FNV the C side uses.
"""
import pathlib, re

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

missing = "".join(re.findall(r'"([^"]*)"',
    src[src.index("SB_GLYPH_MISSING[] ="):src.index("static inline const char *sb_font_glyph")]))
assert len(missing) == 35, len(missing)

# FNV-1a over the glyph bytes, the project's usual checksum shape. Both
# languages compute it over the same table, so a divergence is caught.
h = 0x811C9DC5
for g in glyphs:
    for b in g.encode():
        h = ((h ^ b) * 0x01000193) & 0xFFFFFFFF

rows = []
for lbl, g in zip(labels, glyphs):
    lbl = lbl.replace("%%", "%")
    rows.append(f'    b"{g}",  // {lbl}')

out = f'''/// The glyph table, generated from impl/c/sb_font.h by
/// spec/tools/gen_rust_font.py -- see the test at the bottom of this file.
/// Seven rows of five characters per glyph, '#' set and '.' clear.
#[rustfmt::skip]
static FONT: [&[u8; 35]; {len(glyphs)}] = [
{chr(10).join(rows)}
];

const FONT_CHARS: &[u8] = b"{chars.replace(chr(92), chr(92)*2).replace('"', chr(92) + chr(34))}";

/// Drawn for anything not in the table, so a missing glyph is visible.
static MISSING: [u8; 35] = *b"{missing}";

/// FNV-1a over the glyph bytes. impl/c/sb_font.h holds the same table; if the
/// two ever drift, this is where it shows.
pub const FONT_HASH: u32 = 0x{h:08X};

pub fn glyph(c: u8) -> &'static [u8; 35] {{
    let c = c.to_ascii_uppercase();
    match FONT_CHARS.iter().position(|&k| k == c) {{
        Some(i) => FONT[i],
        None => &MISSING,
    }}
}}
'''

# Splice into hud.rs, replacing the hand-written placeholder block.
hud = ROOT / "impl/rust/src/hud.rs"
s = hud.read_text(encoding="utf-8")
start = s.index("/// The glyph table, generated from") if "/// The glyph table, generated from" in s         else s.index("const FONT_CHARS: &[u8] =")
end = s.index("// ---- actions ---")
s = s[:start] + out + "\n" + s[end:]

if "mod tests" in s:
    hud.write_text(s, encoding="utf-8", newline=chr(10))
    print(f"emitted {len(glyphs)} glyphs, FONT_HASH = 0x{h:08X} (tests kept)")
    raise SystemExit(0)

test = f'''
#[cfg(test)]
mod tests {{
    use super::*;

    /// The C font in impl/c/sb_font.h is the original; this table is generated
    /// from it. The hash is what notices if someone edits one and not the
    /// other -- a divergence would otherwise be one wrong pixel in a HUD
    /// nobody screenshots.
    #[test]
    fn font_matches_the_c_table() {{
        let mut h: u32 = 0x811C_9DC5;
        for g in FONT.iter() {{
            for &b in g.iter() {{
                h = (h ^ b as u32).wrapping_mul(0x0100_0193);
            }}
        }}
        assert_eq!(h, FONT_HASH, "glyph table changed; regenerate from sb_font.h");
        assert_eq!(FONT.len(), FONT_CHARS.len());
    }}

    #[test]
    fn every_glyph_is_five_by_seven() {{
        for (i, g) in FONT.iter().enumerate() {{
            assert_eq!(g.len(), GLYPH_W * GLYPH_H, "glyph {{i}}");
            assert!(g.iter().all(|&b| b == b'#' || b == b'.'), "glyph {{i}}");
        }}
    }}
}}
'''
s = s.rstrip() + "\n" + test
hud.write_text(s, encoding="utf-8", newline="\n")
print(f"emitted {len(glyphs)} glyphs, FONT_HASH = 0x{h:08X}")
