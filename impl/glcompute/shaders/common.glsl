// The shared prelude: buffer bindings and uniforms for every pass.
//
// Concatenated in front of each .comp rather than #included, because
// glslc resolves includes relative to the file and one flat file per
// stage keeps the SPIR-V build a single command with nothing to
// configure. impl/vulkan reuses this file with the default-block
// uniforms swapped for push constants; see impl/vulkan/gen_shaders.py.
#version 430
layout(std430, binding = 0) buffer BGrid    { float grid[]; };
layout(std430, binding = 1) buffer BScratch { float scratch[]; };
layout(std430, binding = 2) buffer BDep     { uint  depcount[]; };
layout(std430, binding = 3) buffer BAx      { float ax[]; };
layout(std430, binding = 4) buffer BAy      { float ay[]; };
layout(std430, binding = 5) buffer BAdir    { uint  adir[]; };
layout(std430, binding = 6) buffer BRng     { uint  arng[]; };
layout(std430, binding = 7) buffer BCos     { float costab[]; };
layout(std430, binding = 8) buffer BSin     { float sintab[]; };
uniform uint  uWidth, uHeight, uLog2w, uXmask, uYmask, uAgents, uCells;
uniform int   uSs, uRs, uNdir;
uniform float uSensorDist, uStep, uDeposit, uDecay;
