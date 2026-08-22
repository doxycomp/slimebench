"""Emit the Haskell font table from impl/c/sb_font.h.

Fourth copy, same argument as gen_rust_font.py and gen_python_font.py: the
glyphs are generated so the four cannot drift, and each carries the same
FNV-32 so a drift that happened anyway is caught at startup rather than seen
as one wrong pixel.
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


def hs_str(s: str) -> str:
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


rows = "\n".join(f"  , {hs_str(g)}  -- {lab}" for g, lab in zip(glyphs[1:], labels[1:]))
out = ROOT / "impl/haskell/src/Font.hs"
out.write_text(f'''-- | The 5x7 bitmap font, generated from impl/c/sb_font.h.
--
-- Do not edit: run spec/tools/gen_haskell_font.py. CI re-runs every generator
-- and fails if the committed output differs.
module Font
  ( glyphW
  , glyphH
  , fontChars
  , fontRows
  , fontHash
  , fontHashConst
  , glyphFor
  ) where

import Data.Bits (xor)
import Data.Char (toUpper)
import Data.List (elemIndex)
import Data.Word (Word32)

glyphW, glyphH :: Int
glyphW = 5
glyphH = 7

fontChars :: String
fontChars = {hs_str(chars)}

-- | One string of 35 characters per glyph, row-major, \'#\' set and \'.\' clear.
fontRows :: [String]
fontRows =
  [ {hs_str(glyphs[0])}  -- {labels[0]}
{rows}
  ]

missingGlyph :: String
missingGlyph = {hs_str(missing)}

-- | The same FNV-32 over the same bytes as sb_font_hash() in C.
fontHashConst :: Word32
fontHashConst = 0x{h:08X}

fontHash :: Word32
fontHash = foldl step 0x811C9DC5 (concat fontRows)
  where
    step acc c = (acc `xor` fromIntegral (fromEnum c)) * 0x01000193

-- | Rows for one character, folded to upper case like the C side.
glyphFor :: Char -> String
glyphFor c = maybe missingGlyph (fontRows !!) (elemIndex (toUpper c) fontChars)
''', encoding="utf-8", newline="\n")
print(f"emitted {len(glyphs)} glyphs, fontHashConst = 0x{h:08X}")
