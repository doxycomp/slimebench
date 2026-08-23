#!/usr/bin/env python3
"""Generate the Vulkan shader set from impl/glcompute/shaders/.

    impl/vulkan/gen_shaders.py

The GLSL bodies are shared with the OpenGL host and must stay shared, or class
G stops being a comparison of two APIs running the same computation and becomes
a comparison of two programs. Only one thing in them is not valid Vulkan GLSL:

    uniform uint uWidth, uHeight, ...;

Vulkan has no default uniform block, so those go into push constants. The
transformation is mechanical and lives here rather than in the shader sources:
the block is declared with the same member names and a `#define` maps each old
name onto it, so every line below the prelude is byte-identical to the OpenGL
version. `git diff` between the two shader trees shows the prelude and nothing
else, which is the property worth having.

Output: shaders/*.comp, ready for glslc. The SPIR-V is compiled at build time
rather than committed, because a .spv blob is not reviewable and the toolchain
that produces it is pinned in versions.env anyway.
"""
from __future__ import annotations

import pathlib
import re
import sys

HERE = pathlib.Path(__file__).resolve().parent
SRC = HERE.parent / "glcompute" / "shaders"
OUT = HERE / "shaders"

# The push-constant block. Order matters only in that the host must write the
# same layout; std430 scalar rules make it the declaration order, and every
# member is four bytes.
PUSH = """layout(push_constant) uniform PC {
  uint  width, height, log2w, xmask, ymask, agents, cells;
  int   ss, rs, ndir;
  float sensorDist, step, deposit, decay;
} pc;

// The names the shared bodies use. Vulkan has no default uniform block, so
// this is the whole difference between the two shader trees.
#define uWidth pc.width
#define uHeight pc.height
#define uLog2w pc.log2w
#define uXmask pc.xmask
#define uYmask pc.ymask
#define uAgents pc.agents
#define uCells pc.cells
#define uSs pc.ss
#define uRs pc.rs
#define uNdir pc.ndir
#define uSensorDist pc.sensorDist
#define uStep pc.step
#define uDeposit pc.deposit
#define uDecay pc.decay
"""

UNIFORM_LINE = re.compile(r"^\s*uniform\s+[^;]*;\s*$", re.M)


def vulkanise(common: str) -> str:
    """common.glsl with the default-block uniforms replaced by push constants."""
    stripped, n = UNIFORM_LINE.subn("", common)
    if n == 0:
        sys.exit("no `uniform` declarations found in common.glsl -- "
                 "has the shared prelude changed shape?")
    return stripped.rstrip() + "\n\n" + PUSH


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    common = (SRC / "common.glsl").read_text(encoding="utf-8")
    (OUT / "common.glsl").write_text(vulkanise(common), encoding="utf-8",
                                     newline="\n")

    bodies = sorted(SRC.glob("*.comp"))
    if not bodies:
        sys.exit(f"no .comp files in {SRC}")
    for b in bodies:
        # Concatenated, not #included: glslc resolves includes relative to the
        # file, and one flat file per stage keeps the SPIR-V build a single
        # command with nothing to configure.
        text = (OUT / "common.glsl").read_text(encoding="utf-8")
        text += "\n" + b.read_text(encoding="utf-8")
        (OUT / b.name).write_text(text, encoding="utf-8", newline="\n")

    print(f"emitted {len(bodies)} shaders into {OUT.relative_to(HERE.parent.parent)}")
    for b in bodies:
        shared = b.read_text(encoding="utf-8")
        got = (OUT / b.name).read_text(encoding="utf-8")
        assert got.endswith(shared), f"{b.name}: body was modified, not appended"
    print("  every body byte-identical to the OpenGL source")
    return 0


if __name__ == "__main__":
    sys.exit(main())
