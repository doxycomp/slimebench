/* slimebench -- OpenGL 4.3 compute implementation of SPEC-1 (class G).
 *
 * The portable counterpart to the CUDA target. Same three kernels, written in
 * GLSL and dispatched through a plain GL context, so it runs on any GPU with
 * GL 4.3 rather than only on NVIDIA. Everything a host language needs to do
 * here is create a context and call five GL functions, which is why class G
 * measures the driver and the shader compiler, not the language.
 *
 * ## Getting at the real GPU under WSL2
 *
 * Linux-side OpenGL in WSL2 defaults to llvmpipe, Mesa's software rasteriser,
 * and Vulkan does not see the NVIDIA card at all (its ICDs point at Windows
 * DLLs). The discrete GPU is reachable through Mesa's D3D12 backend:
 *
 *     GALLIUM_DRIVER=d3d12 MESA_D3D12_DEFAULT_ADAPTER_NAME=NVIDIA
 *
 * The binary prints the renderer string it got, so a run can never silently
 * be a software measurement -- which is exactly the mistake the class-R
 * numbers made before this was understood.
 *
 * Only the GL entry points actually used are loaded, via SDL_GL_GetProcAddress;
 * pulling in GLEW or glad for eighteen functions is not worth the dependency.
 */

#include <SDL.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "../c/dirtable.h"
#include "gl_shaders.h"

#define SPEC_VERSION "SPEC-1"

/* ---- the slice of GL we need -------------------------------------------- */

#define GL_COMPUTE_SHADER            0x91B9
#define GL_COMPILE_STATUS            0x8B81
#define GL_LINK_STATUS               0x8B82
#define GL_SHADER_STORAGE_BUFFER     0x90D2
#define GL_DYNAMIC_COPY              0x88EA
#define GL_ALL_BARRIER_BITS          0xFFFFFFFF
#define GL_RENDERER                  0x1F01
#define GL_VERSION_                  0x1F02

typedef uint32_t GLuint;
typedef int32_t  GLint;
typedef uint32_t GLenum;
typedef int64_t  GLsizeiptr;
typedef int64_t  GLintptr;

static const unsigned char *(*p_glGetString)(GLenum);
static GLuint (*p_glCreateShader)(GLenum);
static void   (*p_glShaderSource)(GLuint, GLint, const char *const *, const GLint *);
static void   (*p_glCompileShader)(GLuint);
static void   (*p_glGetShaderiv)(GLuint, GLenum, GLint *);
static void   (*p_glGetShaderInfoLog)(GLuint, GLint, GLint *, char *);
static GLuint (*p_glCreateProgram)(void);
static void   (*p_glAttachShader)(GLuint, GLuint);
static void   (*p_glLinkProgram)(GLuint);
static void   (*p_glGetProgramiv)(GLuint, GLenum, GLint *);
static void   (*p_glGetProgramInfoLog)(GLuint, GLint, GLint *, char *);
static void   (*p_glUseProgram)(GLuint);
static void   (*p_glGenBuffers)(GLint, GLuint *);
static void   (*p_glBindBuffer)(GLenum, GLuint);
static void   (*p_glBufferData)(GLenum, GLsizeiptr, const void *, GLenum);
static void   (*p_glBufferSubData)(GLenum, GLintptr, GLsizeiptr, const void *);
static void   (*p_glGetBufferSubData)(GLenum, GLintptr, GLsizeiptr, void *);
static void   (*p_glBindBufferBase)(GLenum, GLuint, GLuint);
static void   (*p_glDispatchCompute)(GLuint, GLuint, GLuint);
static void   (*p_glMemoryBarrier)(GLenum);
static GLint  (*p_glGetUniformLocation)(GLuint, const char *);
static void   (*p_glUniform1ui)(GLint, GLuint);
static void   (*p_glUniform1i)(GLint, GLint);
static void   (*p_glUniform1f)(GLint, float);
static void   (*p_glFinish)(void);

static int load_gl(void) {
#define L(sym)                                                              \
    do {                                                                    \
        *(void **)(&p_##sym) = SDL_GL_GetProcAddress(#sym);                 \
        if (!p_##sym) { fprintf(stderr, "missing GL entry point: %s\n", #sym); return 1; } \
    } while (0)
    L(glGetString); L(glCreateShader); L(glShaderSource); L(glCompileShader);
    L(glGetShaderiv); L(glGetShaderInfoLog); L(glCreateProgram); L(glAttachShader);
    L(glLinkProgram); L(glGetProgramiv); L(glGetProgramInfoLog); L(glUseProgram);
    L(glGenBuffers); L(glBindBuffer); L(glBufferData); L(glBufferSubData);
    L(glGetBufferSubData); L(glBindBufferBase); L(glDispatchCompute);
    L(glMemoryBarrier); L(glGetUniformLocation); L(glUniform1ui);
    L(glUniform1i); L(glUniform1f); L(glFinish);
#undef L
    return 0;
}

static GLuint build(const char *src, const char *name) {
    GLuint sh = p_glCreateShader(GL_COMPUTE_SHADER);
    p_glShaderSource(sh, 1, &src, NULL);
    p_glCompileShader(sh);
    GLint ok = 0;
    p_glGetShaderiv(sh, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        char log[8192];
        p_glGetShaderInfoLog(sh, sizeof log, NULL, log);
        fprintf(stderr, "compile failed (%s):\n%s\n", name, log);
        exit(1);
    }
    GLuint pr = p_glCreateProgram();
    p_glAttachShader(pr, sh);
    p_glLinkProgram(pr);
    p_glGetProgramiv(pr, GL_LINK_STATUS, &ok);
    if (!ok) {
        char log[8192];
        p_glGetProgramInfoLog(pr, sizeof log, NULL, log);
        fprintf(stderr, "link failed (%s):\n%s\n", name, log);
        exit(1);
    }
    return pr;
}

/* ---- host-side PRNG, identical to SPEC-1 section 3 ---------------------- */

static uint32_t splitmix32(uint32_t *s) {
    uint32_t z = (*s += 0x9E3779B9u);
    z = (z ^ (z >> 16)) * 0x21F0AAADu;
    z = (z ^ (z >> 15)) * 0x735A2D97u;
    return z ^ (z >> 15);
}

static uint32_t rotl32(uint32_t x, int k) { return (x << k) | (x >> (32 - k)); }

static uint32_t xoshiro(uint32_t *s) {
    const uint32_t r = rotl32(s[0] + s[3], 7) + s[0];
    const uint32_t t = s[1] << 9;
    s[2] ^= s[0]; s[3] ^= s[1]; s[1] ^= s[2]; s[0] ^= s[3];
    s[2] ^= t; s[3] = rotl32(s[3], 11);
    return r;
}

static float rnd01(uint32_t u) { return (float)(u >> 8) / 16777216.0f; }
static uint32_t fnv(uint32_t h, uint32_t w) { return (h ^ w) * 0x01000193u; }

static double now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1e3 + ts.tv_nsec / 1e6;
}

static int cmpd(const void *a, const void *b) {
    const double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}

/* ---- main ---------------------------------------------------------------- */

typedef struct {
    uint32_t width, height, agents, ticks, warmup, seed;
    float sensor_dist, step, deposit, decay;
    uint32_t ss, rs;
    const char *preset;
    int json;
    const char *dump_grid;
} opts;

static void usage(FILE *f, const char *a0) {
    fprintf(f,
        "usage: %s [options]   (slimebench " SPEC_VERSION ", GL compute, class G)\n"
        "  --preset NAME        tiny|small|medium|large|browser\n"
        "  --width N --height N powers of two\n"
        "  --agents N  --ticks N  --warmup N  --seed N\n"
        "  --update MODE        deferred only (serial is refused)\n"
        "  --sensor-dist F  --sensor-steps N  --rot-steps N\n"
        "  --step F  --deposit F  --decay F\n"
        "  --headless  --json  --dump-grid PATH\n"
        "  -h, --help\n"
        "\n"
        "  For the discrete GPU under WSL2, run with:\n"
        "    GALLIUM_DRIVER=d3d12 MESA_D3D12_DEFAULT_ADAPTER_NAME=NVIDIA\n",
        a0);
}

int main(int argc, char **argv) {
    opts o = {1024, 1024, 262144, 1000, 0, 12345,
              9.0f, 1.0f, 10.0f, 0.94f, 144, 144, "custom", 0, NULL};

#define NEED()                                                              \
    (++i < argc ? argv[i]                                                   \
                : (fprintf(stderr, "error: %s requires a value\n", argv[i-1]), exit(2), ""))

    for (int i = 1; i < argc; i++) {
        const char *a = argv[i];
        if (!strcmp(a, "-h") || !strcmp(a, "--help")) { usage(stdout, argv[0]); return 0; }
        else if (!strcmp(a, "--preset")) {
            const char *p = NEED();
            if (!strcmp(p, "tiny"))        { o.width=512;  o.height=512;  o.agents=65536;   o.ticks=1000; }
            else if (!strcmp(p, "small"))  { o.width=1024; o.height=1024; o.agents=262144;  o.ticks=1000; }
            else if (!strcmp(p, "medium")) { o.width=2048; o.height=2048; o.agents=1048576; o.ticks=1000; }
            else if (!strcmp(p, "large"))  { o.width=4096; o.height=4096; o.agents=4194304; o.ticks=500; }
            else if (!strcmp(p, "browser")){ o.width=1024; o.height=1024; o.agents=262144;  o.ticks=0; }
            else { fprintf(stderr, "error: unknown preset '%s'\n", p); return 2; }
            o.preset = p;
        }
        else if (!strcmp(a, "--width"))  { o.width  = strtoul(NEED(), NULL, 10); o.preset = "custom"; }
        else if (!strcmp(a, "--height")) { o.height = strtoul(NEED(), NULL, 10); o.preset = "custom"; }
        else if (!strcmp(a, "--agents")) { o.agents = strtoul(NEED(), NULL, 10); o.preset = "custom"; }
        else if (!strcmp(a, "--ticks"))  { o.ticks  = strtoul(NEED(), NULL, 10); }
        else if (!strcmp(a, "--warmup")) { o.warmup = strtoul(NEED(), NULL, 10); }
        else if (!strcmp(a, "--seed"))   { o.seed   = strtoul(NEED(), NULL, 10); }
        else if (!strcmp(a, "--sensor-steps")) { o.ss = strtoul(NEED(), NULL, 10); }
        else if (!strcmp(a, "--rot-steps"))    { o.rs = strtoul(NEED(), NULL, 10); }
        else if (!strcmp(a, "--sensor-dist"))  { o.sensor_dist = strtof(NEED(), NULL); }
        else if (!strcmp(a, "--step"))         { o.step = strtof(NEED(), NULL); }
        else if (!strcmp(a, "--deposit"))      { o.deposit = strtof(NEED(), NULL); }
        else if (!strcmp(a, "--decay"))        { o.decay = strtof(NEED(), NULL); }
        else if (!strcmp(a, "--dump-grid"))    { o.dump_grid = NEED(); }
        else if (!strcmp(a, "--threads"))      { (void)NEED(); }
        else if (!strcmp(a, "--update")) {
            const char *m = NEED();
            if (!strcmp(m, "serial")) {
                fprintf(stderr,
                    "error: the GL compute target implements --update deferred only.\n"
                    "       SPEC-1 'serial' makes an agent's deposit visible to the\n"
                    "       next agent in the same tick, a sequential dependency a\n"
                    "       GPU cannot express.\n");
                return 3;
            }
            if (strcmp(m, "deferred")) {
                fprintf(stderr, "error: --update must be serial|deferred\n");
                return 2;
            }
        }
        else if (!strcmp(a, "--headless")) { }
        else if (!strcmp(a, "--json"))     { o.json = 1; }
        else {
            /* SPEC-1 section 10: never silently ignore an unknown flag. */
            fprintf(stderr, "error: unknown argument '%s'\n", a);
            usage(stderr, argv[0]);
            return 2;
        }
    }
#undef NEED

    if (!o.width || (o.width & (o.width - 1)) || !o.height || (o.height & (o.height - 1))) {
        fprintf(stderr, "error: width and height must be powers of two\n");
        return 2;
    }

    const size_t cells = (size_t)o.width * o.height;
    uint32_t log2w = 0;
    while ((1u << log2w) < o.width) log2w++;

    /* ---- host init, SPEC-1 section 3.3 ---------------------------------- */
    float *grid = malloc(cells * 4);
    uint32_t sm = o.seed ^ 0x5BF03635u;
    for (size_t i = 0; i < cells; i++) grid[i] = rnd01(splitmix32(&sm)) * 100.0f;

    float *ax = malloc((size_t)o.agents * 4);
    float *ay = malloc((size_t)o.agents * 4);
    uint32_t *adir = malloc((size_t)o.agents * 4);   /* std430 has no uint16 */
    uint32_t *arng = malloc((size_t)o.agents * 16);
    const float fw = (float)o.width, fh = (float)o.height;
    for (uint32_t i = 0; i < o.agents; i++) {
        uint32_t a = o.seed + 0x9E3779B9u * (i + 1u);
        uint32_t *r = &arng[(size_t)i * 4];
        r[0] = splitmix32(&a); r[1] = splitmix32(&a);
        r[2] = splitmix32(&a); r[3] = splitmix32(&a);
        if ((r[0] | r[1] | r[2] | r[3]) == 0u) r[0] = 1u;
        ax[i] = rnd01(xoshiro(r)) * fw;
        ay[i] = rnd01(xoshiro(r)) * fh;
        adir[i] = xoshiro(r) % SB_NDIR;
    }

    float costab[SB_NDIR], sintab[SB_NDIR];
    for (int d = 0; d < SB_NDIR; d++) {
        memcpy(&costab[d], &SB_COS_BITS[d], 4);
        memcpy(&sintab[d], &SB_SIN_BITS[d], 4);
    }

    /* ---- GL context ------------------------------------------------------ */
    if (SDL_Init(SDL_INIT_VIDEO) != 0) {
        fprintf(stderr, "SDL_Init: %s\n", SDL_GetError());
        return 1;
    }
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 4);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 3);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_CORE);
    SDL_Window *win = SDL_CreateWindow("slimebench-gl", 0, 0, 64, 64,
                                       SDL_WINDOW_OPENGL | SDL_WINDOW_HIDDEN);
    if (!win) { fprintf(stderr, "CreateWindow: %s\n", SDL_GetError()); return 1; }
    SDL_GLContext ctx = SDL_GL_CreateContext(win);
    if (!ctx) { fprintf(stderr, "GL 4.3 core context: %s\n", SDL_GetError()); return 1; }
    if (load_gl()) return 1;

    const char *renderer = (const char *)p_glGetString(GL_RENDERER);

    GLuint pr_agents  = build(SB_GLSL_AGENTS,  "agents");
    GLuint pr_merge   = build(SB_GLSL_MERGE,   "merge");
    GLuint pr_diffuse = build(SB_GLSL_DIFFUSE, "diffuse");

    /* ---- buffers --------------------------------------------------------- */
    GLuint buf[9];
    for (int i = 0; i < 9; i++) p_glGenBuffers(1, &buf[i]);
    struct { int idx; GLsizeiptr bytes; const void *data; } bufs[] = {
        {0, (GLsizeiptr)cells * 4,          grid},
        {1, (GLsizeiptr)cells * 4,          NULL},
        {2, (GLsizeiptr)cells * 4,          NULL},
        {3, (GLsizeiptr)o.agents * 4,       ax},
        {4, (GLsizeiptr)o.agents * 4,       ay},
        {5, (GLsizeiptr)o.agents * 4,       adir},
        {6, (GLsizeiptr)o.agents * 16,      arng},
        {7, (GLsizeiptr)SB_NDIR * 4,        costab},
        {8, (GLsizeiptr)SB_NDIR * 4,        sintab},
    };
    uint32_t *zeros = calloc(cells, 4);
    for (size_t i = 0; i < sizeof bufs / sizeof bufs[0]; i++) {
        p_glBindBuffer(GL_SHADER_STORAGE_BUFFER, buf[bufs[i].idx]);
        p_glBufferData(GL_SHADER_STORAGE_BUFFER, bufs[i].bytes,
                       bufs[i].data ? bufs[i].data : (const void *)zeros,
                       GL_DYNAMIC_COPY);
        p_glBindBufferBase(GL_SHADER_STORAGE_BUFFER, bufs[i].idx, buf[bufs[i].idx]);
    }
    free(zeros);

    /* Uniforms are per-program in GL, so set them on all three. */
    GLuint programs[3] = {pr_agents, pr_merge, pr_diffuse};
    for (int k = 0; k < 3; k++) {
        p_glUseProgram(programs[k]);
#define U1UI(n, v) do { GLint l = p_glGetUniformLocation(programs[k], n); if (l >= 0) p_glUniform1ui(l, (GLuint)(v)); } while (0)
#define U1I(n, v)  do { GLint l = p_glGetUniformLocation(programs[k], n); if (l >= 0) p_glUniform1i(l, (GLint)(v)); } while (0)
#define U1F(n, v)  do { GLint l = p_glGetUniformLocation(programs[k], n); if (l >= 0) p_glUniform1f(l, (float)(v)); } while (0)
        U1UI("uWidth", o.width);   U1UI("uHeight", o.height);
        U1UI("uLog2w", log2w);     U1UI("uXmask", o.width - 1);
        U1UI("uYmask", o.height - 1);
        U1UI("uAgents", o.agents); U1UI("uCells", (GLuint)cells);
        U1I("uSs", (int)o.ss);     U1I("uRs", (int)o.rs);
        U1I("uNdir", SB_NDIR);
        U1F("uSensorDist", o.sensor_dist); U1F("uStep", o.step);
        U1F("uDeposit", o.deposit);        U1F("uDecay", o.decay);
#undef U1UI
#undef U1I
#undef U1F
    }

    const GLuint ag_groups = (o.agents + 63u) / 64u;
    const GLuint cl_groups = (GLuint)((cells + 63) / 64);
    int grid_is_buf0 = 1;   /* which SSBO currently holds the live grid */

    /* Ping-pong by rebinding rather than copying: the diffusion shader always
     * reads binding 0 and writes binding 1, so swapping which buffer object
     * sits at each binding point is the whole buffer swap. */
#define SB_GL_TICK()                                                          \
    do {                                                                      \
        const int _live  = grid_is_buf0 ? 0 : 1;                              \
        const int _other = grid_is_buf0 ? 1 : 0;                              \
        p_glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 0, buf[_live]);          \
        p_glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 1, buf[_other]);         \
        p_glUseProgram(pr_agents);                                            \
        p_glDispatchCompute(ag_groups, 1, 1);                                 \
        p_glMemoryBarrier(GL_ALL_BARRIER_BITS);                               \
        p_glUseProgram(pr_merge);                                             \
        p_glDispatchCompute(cl_groups, 1, 1);                                 \
        p_glMemoryBarrier(GL_ALL_BARRIER_BITS);                               \
        p_glUseProgram(pr_diffuse);                                           \
        p_glDispatchCompute(cl_groups, 1, 1);                                 \
        p_glMemoryBarrier(GL_ALL_BARRIER_BITS);                               \
        grid_is_buf0 = !grid_is_buf0;                                         \
    } while (0)

    /* Exactly `warmup` ticks here and exactly `ticks` below -- the state the
     * hashes see must be the state after warmup+ticks, no more. */
    for (uint32_t t = 0; t < o.warmup; t++) SB_GL_TICK();
    p_glFinish();

    double *tick_ms = malloc((o.ticks ? o.ticks : 1) * sizeof(double));
    const double t_start = now_ms();
    for (uint32_t t = 0; t < o.ticks; t++) {
        const double a = now_ms();
        SB_GL_TICK();
        p_glFinish();
        tick_ms[t] = now_ms() - a;
    }
    const double ms_total = now_ms() - t_start;
#undef SB_GL_TICK

    /* ---- read back and hash ---------------------------------------------- */
    const int live = grid_is_buf0 ? 0 : 1;
    p_glBindBuffer(GL_SHADER_STORAGE_BUFFER, buf[live]);
    p_glGetBufferSubData(GL_SHADER_STORAGE_BUFFER, 0, (GLsizeiptr)cells * 4, grid);
    p_glBindBuffer(GL_SHADER_STORAGE_BUFFER, buf[3]);
    p_glGetBufferSubData(GL_SHADER_STORAGE_BUFFER, 0, (GLsizeiptr)o.agents * 4, ax);
    p_glBindBuffer(GL_SHADER_STORAGE_BUFFER, buf[4]);
    p_glGetBufferSubData(GL_SHADER_STORAGE_BUFFER, 0, (GLsizeiptr)o.agents * 4, ay);
    p_glBindBuffer(GL_SHADER_STORAGE_BUFFER, buf[5]);
    p_glGetBufferSubData(GL_SHADER_STORAGE_BUFFER, 0, (GLsizeiptr)o.agents * 4, adir);

    uint32_t gh = 0x811C9DC5u;
    for (size_t i = 0; i < cells; i++) {
        uint32_t w; memcpy(&w, &grid[i], 4); gh = fnv(gh, w);
    }
    uint32_t agh = 0x811C9DC5u;
    for (uint32_t i = 0; i < o.agents; i++) {
        uint32_t w;
        memcpy(&w, &ax[i], 4); agh = fnv(agh, w);
        memcpy(&w, &ay[i], 4); agh = fnv(agh, w);
        agh = fnv(agh, adir[i]);
    }
    uint32_t dh = 0x811C9DC5u;
    for (int d = 0; d < SB_NDIR; d++) dh = fnv(dh, SB_COS_BITS[d]);
    for (int d = 0; d < SB_NDIR; d++) dh = fnv(dh, SB_SIN_BITS[d]);

    if (o.dump_grid) {
        FILE *f = fopen(o.dump_grid, "wb");
        if (f) { fwrite(grid, 4, cells, f); fclose(f); }
    }

    const size_t n = o.ticks;
    double median = 0, p99 = 0, mean = 0;
    if (n) {
        double *srt = malloc(n * sizeof(double));
        memcpy(srt, tick_ms, n * sizeof(double));
        qsort(srt, n, sizeof(double), cmpd);
        median = srt[n / 2];
        size_t pi = (size_t)(n * 0.99); if (pi >= n) pi = n - 1;
        p99 = srt[pi];
        for (size_t i = 0; i < n; i++) mean += tick_ms[i];
        mean /= (double)n;
        free(srt);
    }

    if (o.json) {
        printf("{\"schema\":1,\"impl\":\"glcompute\",\"backend\":\"gl43\",\"class\":\"G\","
               "\"preset\":\"%s\",\"variant\":\"%s\","
               "\"width\":%u,\"height\":%u,\"agents\":%u,\"ticks\":%zu,\"seed\":%u,"
               "\"update\":\"deferred\",\"threads\":1,"
               "\"grid_hash\":\"0x%08X\",\"agent_hash\":\"0x%08X\",\"dirtable_hash\":\"0x%08X\","
               "\"ms_total\":%.4f,\"ms_agents\":0.0,\"ms_diffuse\":0.0,"
               "\"ms_per_tick_mean\":%.6f,\"ms_per_tick_median\":%.6f,\"ms_per_tick_p99\":%.6f,"
               "\"maups\":%.4f,\"mcups\":%.4f}\n",
               o.preset, renderer ? renderer : "unknown",
               o.width, o.height, o.agents, n, o.seed,
               gh, agh, dh, ms_total, mean, median, p99,
               ms_total > 0 ? (double)o.agents * n / ms_total / 1000.0 : 0.0,
               ms_total > 0 ? (double)cells * n / ms_total / 1000.0 : 0.0);
    } else {
        printf("%s %ux%u agents=%u ticks=%u update=deferred\n",
               o.preset, o.width, o.height, o.agents, o.ticks);
        printf("  renderer   %s\n", renderer ? renderer : "unknown");
        printf("  grid_hash  0x%08X\n", gh);
        printf("  agent_hash 0x%08X\n", agh);
        printf("  total      %.2f ms  (%.4f ms/tick)\n",
               ms_total, o.ticks ? ms_total / o.ticks : 0.0);
    }

    free(tick_ms); free(grid); free(ax); free(ay); free(adir); free(arng);
    SDL_GL_DeleteContext(ctx);
    SDL_DestroyWindow(win);
    SDL_Quit();
    return 0;
}
