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
