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

layout(push_constant) uniform PC {
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
