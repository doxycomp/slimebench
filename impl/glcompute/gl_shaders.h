/* GLSL 4.3 compute kernels -- the SPEC-1 tick, one shader per pass.
 *
 * `precise` is what keeps this bit-exact: it forbids the driver from
 * reassociating and from fusing a multiply and an add into one rounding.
 *
 * It is needed in more places than the obvious one. Marking only the
 * diffusion accumulator was not enough: `x + cos*step` in the agent pass gets
 * fused too, which moves an agent by an ULP and eventually sends it the other
 * way at a sensor comparison. Mesa's llvmpipe happened not to fuse and was
 * exact; the D3D12/NVIDIA path fused and diverged in the *agent* hash, which
 * is what pointed at the agent pass rather than the stencil.
 *
 * Deposits use `atomicAdd` on a uint counter rather than on a float. Integer
 * addition is exact and order-independent, so the count is deterministic no
 * matter how the invocations interleave; the multiply by `deposit` happens
 * once, in the merge pass. Same trick as the CUDA target, same caveat: it
 * reproduces the serial chain only while k*deposit stays exactly representable.
 */
#ifndef SB_GL_SHADERS_H
#define SB_GL_SHADERS_H

#define SB_GLSL_COMMON                                                        \
    "#version 430\n"                                                          \
    "layout(std430, binding = 0) buffer BGrid    { float grid[]; };\n"        \
    "layout(std430, binding = 1) buffer BScratch { float scratch[]; };\n"     \
    "layout(std430, binding = 2) buffer BDep     { uint  depcount[]; };\n"    \
    "layout(std430, binding = 3) buffer BAx      { float ax[]; };\n"          \
    "layout(std430, binding = 4) buffer BAy      { float ay[]; };\n"          \
    "layout(std430, binding = 5) buffer BAdir    { uint  adir[]; };\n"        \
    "layout(std430, binding = 6) buffer BRng     { uint  arng[]; };\n"        \
    "layout(std430, binding = 7) buffer BCos     { float costab[]; };\n"      \
    "layout(std430, binding = 8) buffer BSin     { float sintab[]; };\n"      \
    "uniform uint  uWidth, uHeight, uLog2w, uXmask, uYmask, uAgents, uCells;\n" \
    "uniform int   uSs, uRs, uNdir;\n"                                        \
    "uniform float uSensorDist, uStep, uDeposit, uDecay;\n"

static const char *SB_GLSL_AGENTS =
    SB_GLSL_COMMON
    "layout(local_size_x = 64) in;\n"
    "uint rotl32(uint x, int k) { return (x << k) | (x >> (32 - k)); }\n"
    "float wrapf(float v, float m) {\n"
    "  if (v < 0.0) v = v + m;\n"
    "  if (v >= m)  v = v - m;\n"
    "  return v;\n"
    "}\n"
    /* `precise` propagates back through everything contributing to the value,
     * including the multiply-add inside the wrapf() argument -- which is the
     * operation drivers fuse. */
    "float senseAt(float x, float y, int d) {\n"
    "  precise float sx = wrapf(x + costab[d] * uSensorDist, float(uWidth));\n"
    "  precise float sy = wrapf(y + sintab[d] * uSensorDist, float(uHeight));\n"
    "  return grid[((uint(sy) & uYmask) << uLog2w) | (uint(sx) & uXmask)];\n"
    "}\n"
    "void main() {\n"
    "  uint i = gl_GlobalInvocationID.x;\n"
    "  if (i >= uAgents) return;\n"
    "  int d = int(adir[i]);\n"
    "  float x = ax[i];\n"
    "  float y = ay[i];\n"
    "  int dl = (d - uSs + uNdir) % uNdir;\n"
    "  int dr = (d + uSs) % uNdir;\n"
    "  float fl = senseAt(x, y, dl);\n"
    "  float fc = senseAt(x, y, d);\n"
    "  float fr = senseAt(x, y, dr);\n"
    "  if (fc >= fl && fc >= fr) {\n"
    "  } else if (fc < fl && fc < fr) {\n"
    "    uint o = i * 4u;\n"
    "    uint s0 = arng[o], s1 = arng[o+1u], s2 = arng[o+2u], s3 = arng[o+3u];\n"
    "    uint res = rotl32(s0 + s3, 7) + s0;\n"
    "    uint t = s1 << 9;\n"
    "    s2 ^= s0; s3 ^= s1; s1 ^= s2; s0 ^= s3; s2 ^= t; s3 = rotl32(s3, 11);\n"
    "    arng[o] = s0; arng[o+1u] = s1; arng[o+2u] = s2; arng[o+3u] = s3;\n"
    "    d = ((res & 1u) != 0u) ? (d + uRs) % uNdir : (d - uRs + uNdir) % uNdir;\n"
    "  } else if (fl > fr) {\n"
    "    d = (d - uRs + uNdir) % uNdir;\n"
    "  } else {\n"
    "    d = (d + uRs) % uNdir;\n"
    "  }\n"
    "  precise float nx = wrapf(x + costab[d] * uStep, float(uWidth));\n"
    "  precise float ny = wrapf(y + sintab[d] * uStep, float(uHeight));\n"
    "  x = nx;\n"
    "  y = ny;\n"
    "  uint idx = ((uint(y) & uYmask) << uLog2w) | (uint(x) & uXmask);\n"
    "  atomicAdd(depcount[idx], 1u);\n"
    "  adir[i] = uint(d);\n"
    "  ax[i] = x;\n"
    "  ay[i] = y;\n"
    "}\n";

static const char *SB_GLSL_MERGE =
    SB_GLSL_COMMON
    "layout(local_size_x = 64) in;\n"
    "void main() {\n"
    "  uint i = gl_GlobalInvocationID.x;\n"
    "  if (i >= uCells) return;\n"
    "  uint c = depcount[i];\n"
    "  if (c != 0u) {\n"
    "    precise float add = float(c) * uDeposit;\n"
    "    grid[i] = grid[i] + add;\n"
    "    depcount[i] = 0u;\n"
    "  }\n"
    "}\n";

static const char *SB_GLSL_DIFFUSE =
    SB_GLSL_COMMON
    "layout(local_size_x = 64) in;\n"
    "void main() {\n"
    "  uint i = gl_GlobalInvocationID.x;\n"
    "  if (i >= uCells) return;\n"
    "  uint x = i & uXmask;\n"
    "  uint y = i >> uLog2w;\n"
    "  uint xm = (x - 1u) & uXmask;\n"
    "  uint xp = (x + 1u) & uXmask;\n"
    "  uint rowm = ((y - 1u) & uYmask) << uLog2w;\n"
    "  uint row0 = y << uLog2w;\n"
    "  uint rowp = ((y + 1u) & uYmask) << uLog2w;\n"
    /* `precise` is load-bearing: it pins the summation order of SPEC-1 5.4
     * and blocks multiply-add fusion. */
    "  precise float acc = grid[rowm | xm];\n"
    "  acc = acc + grid[rowm | x];\n"
    "  acc = acc + grid[rowm | xp];\n"
    "  acc = acc + grid[row0 | xm];\n"
    "  acc = acc + 4.0 * grid[row0 | x];\n"
    "  acc = acc + grid[row0 | xp];\n"
    "  acc = acc + grid[rowp | xm];\n"
    "  acc = acc + grid[rowp | x];\n"
    "  acc = acc + grid[rowp | xp];\n"
    "  scratch[row0 | x] = (acc / 12.0) * uDecay;\n"
    "}\n";

#endif /* SB_GL_SHADERS_H */
