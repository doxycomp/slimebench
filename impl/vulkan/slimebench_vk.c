/* slimebench -- Vulkan compute host (benchmark class G).
 *
 * ## Why a third GPU API
 *
 * CUDA runs on one vendor. The GLSL 4.3 host runs anywhere OpenGL does, which
 * under WSL2 means Mesa translating to D3D12. Vulkan is the only one of the
 * three that reaches an AMD, an Intel and an NVIDIA part through the same
 * driver interface, which is what turns "how fast is this GPU" from a question
 * about one vendor into a question about a machine.
 *
 * The shaders are the OpenGL ones. impl/vulkan/gen_shaders.py does exactly one
 * thing to them -- moves the default-block uniforms into push constants,
 * because Vulkan has no default block -- and asserts that every line below the
 * prelude is byte-identical. So a difference between the GL and Vulkan rows is
 * a difference between drivers, not between programs.
 *
 * ## Conformance
 *
 * Same position as the GL host: whether this is tier A depends on the driver,
 * not on the API. SPEC-1 5.4 fixes the order of the nine additions and the
 * shaders express that order with `precise`, which forbids the reassociation
 * and the fusing that would change it. A driver that honours `precise` is
 * bit-exact; one that does not is not, and the row says which.
 *
 * ## What this host does not do
 *
 * No pipelining, no double buffering, no async compute. One command buffer per
 * tick, three dispatches, a barrier between each. The GL host is written the
 * same way and for the same reason: the measurement is the kernel, and a host
 * that overlapped ticks would be measuring its own cleverness.
 */
#define _POSIX_C_SOURCE 200809L

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include <vulkan/vulkan.h>

#include "../c/dirtable.h"

#define VK_CHECK(x)                                                          \
    do {                                                                     \
        VkResult _r = (x);                                                   \
        if (_r != VK_SUCCESS) {                                              \
            fprintf(stderr, "vulkan: %s failed (%d) at %s:%d\n",             \
                    #x, (int)_r, __FILE__, __LINE__);                        \
            exit(3);                                                         \
        }                                                                    \
    } while (0)

/* The nine storage buffers the shaders bind, in binding order. */
enum {
    B_GRID, B_SCRATCH, B_DEP, B_AX, B_AY, B_ADIR, B_ARNG, B_COS, B_SIN,
    B_COUNT
};

/* Mirrors the push-constant block in impl/vulkan/shaders/common.glsl. Every
 * member is four bytes, so the C layout and the std430 scalar layout agree
 * without padding -- checked by _Static_assert rather than assumed. */
typedef struct {
    uint32_t width, height, log2w, xmask, ymask, agents, cells;
    int32_t ss, rs, ndir;
    float sensor_dist, step, deposit, decay;
} vk_push;
_Static_assert(sizeof(vk_push) == 14 * 4, "push constants must be tightly packed");

typedef struct {
    VkBuffer buf;
    VkDeviceMemory mem;
    VkDeviceSize size;
} vk_buffer;

typedef struct {
    VkInstance inst;
    VkPhysicalDevice phys;
    VkDevice dev;
    VkQueue queue;
    uint32_t qfam;
    VkCommandPool pool;
    VkCommandBuffer cmd;
    VkDescriptorSetLayout dsl;
    VkDescriptorPool dpool;
    VkDescriptorSet dsets[2];
    VkPipelineLayout playout;
    VkPipeline pipe[3];          /* agents, merge, diffuse */
    vk_buffer bufs[B_COUNT];
    vk_buffer staging;
    char device_name[256];
    int host_visible;            /* device-local memory the host can map */
} vk_ctx;

/* ---- memory ------------------------------------------------------------- */

static uint32_t find_memory(VkPhysicalDevice p, uint32_t bits,
                            VkMemoryPropertyFlags want) {
    VkPhysicalDeviceMemoryProperties mp;
    vkGetPhysicalDeviceMemoryProperties(p, &mp);
    for (uint32_t i = 0; i < mp.memoryTypeCount; i++)
        if ((bits & (1u << i)) &&
            (mp.memoryTypes[i].propertyFlags & want) == want)
            return i;
    return UINT32_MAX;
}

static void buffer_create(vk_ctx *c, vk_buffer *b, VkDeviceSize size,
                          VkBufferUsageFlags usage,
                          VkMemoryPropertyFlags props) {
    b->size = size;
    VkBufferCreateInfo bi = {
        .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
        .size = size, .usage = usage,
        .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
    };
    VK_CHECK(vkCreateBuffer(c->dev, &bi, NULL, &b->buf));

    VkMemoryRequirements mr;
    vkGetBufferMemoryRequirements(c->dev, b->buf, &mr);
    uint32_t type = find_memory(c->phys, mr.memoryTypeBits, props);
    if (type == UINT32_MAX) {
        fprintf(stderr, "vulkan: no memory type with the required properties\n");
        exit(3);
    }
    VkMemoryAllocateInfo ai = {
        .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .allocationSize = mr.size, .memoryTypeIndex = type,
    };
    VK_CHECK(vkAllocateMemory(c->dev, &ai, NULL, &b->mem));
    VK_CHECK(vkBindBufferMemory(c->dev, b->buf, b->mem, 0));
}

static void buffer_free(vk_ctx *c, vk_buffer *b) {
    if (b->buf) vkDestroyBuffer(c->dev, b->buf, NULL);
    if (b->mem) vkFreeMemory(c->dev, b->mem, NULL);
    b->buf = VK_NULL_HANDLE;
    b->mem = VK_NULL_HANDLE;
}

/* One submit, waited on. Every transfer and every tick goes through this: a
 * host that overlapped them would be measuring its own scheduling. */
static void submit_and_wait(vk_ctx *c) {
    VkSubmitInfo si = {
        .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .commandBufferCount = 1, .pCommandBuffers = &c->cmd,
    };
    VK_CHECK(vkQueueSubmit(c->queue, 1, &si, VK_NULL_HANDLE));
    VK_CHECK(vkQueueWaitIdle(c->queue));
}

static void upload(vk_ctx *c, vk_buffer *dst, const void *src, size_t n) {
    void *p;
    VK_CHECK(vkMapMemory(c->dev, c->staging.mem, 0, n, 0, &p));
    memcpy(p, src, n);
    vkUnmapMemory(c->dev, c->staging.mem);

    VkCommandBufferBeginInfo bi = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
    };
    VK_CHECK(vkBeginCommandBuffer(c->cmd, &bi));
    VkBufferCopy region = { .size = n };
    vkCmdCopyBuffer(c->cmd, c->staging.buf, dst->buf, 1, &region);
    VK_CHECK(vkEndCommandBuffer(c->cmd));
    submit_and_wait(c);
}

static void download(vk_ctx *c, vk_buffer *src, void *dst, size_t n) {
    VkCommandBufferBeginInfo bi = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
    };
    VK_CHECK(vkBeginCommandBuffer(c->cmd, &bi));
    VkBufferCopy region = { .size = n };
    vkCmdCopyBuffer(c->cmd, src->buf, c->staging.buf, 1, &region);
    VK_CHECK(vkEndCommandBuffer(c->cmd));
    submit_and_wait(c);

    void *p;
    VK_CHECK(vkMapMemory(c->dev, c->staging.mem, 0, n, 0, &p));
    memcpy(dst, p, n);
    vkUnmapMemory(c->dev, c->staging.mem);
}

/* ---- setup -------------------------------------------------------------- */

/* -1 discrete-or-anything, -2 cpu, -3 integrated, >=0 an explicit index. */
#define SB_VK_ANY (-1)
#define SB_VK_CPU (-2)
#define SB_VK_IGPU (-3)

static void pick_device(vk_ctx *c, int want_index) {
    uint32_t n = 0;
    VK_CHECK(vkEnumeratePhysicalDevices(c->inst, &n, NULL));
    if (n == 0) {
        fprintf(stderr, "vulkan: no physical devices. On WSL2 that usually "
                        "means no Vulkan ICD reaches the GPU -- see "
                        "docs/RESULTS.md class G.\n");
        exit(3);
    }
    VkPhysicalDevice *devs = calloc(n, sizeof *devs);
    VK_CHECK(vkEnumeratePhysicalDevices(c->inst, &n, devs));

    /* A discrete part unless told otherwise: on a machine with both, the
     * software rasteriser would otherwise win the enumeration and the row
     * would say "GPU" while measuring a CPU. */
    int chosen = -1;
    for (uint32_t i = 0; i < n; i++) {
        VkPhysicalDeviceProperties pr;
        vkGetPhysicalDeviceProperties(devs[i], &pr);
        if (want_index >= 0) { if ((int)i == want_index) chosen = (int)i; continue; }
        if (want_index == SB_VK_CPU) {
            if (pr.deviceType == VK_PHYSICAL_DEVICE_TYPE_CPU) { chosen = (int)i; break; }
            continue;
        }
        if (want_index == SB_VK_IGPU) {
            if (pr.deviceType == VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU) { chosen = (int)i; break; }
            continue;
        }
        if (pr.deviceType == VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU) { chosen = (int)i; break; }
        if (chosen < 0 && pr.deviceType != VK_PHYSICAL_DEVICE_TYPE_CPU) chosen = (int)i;
    }
    if (chosen < 0) {
        if (want_index == SB_VK_CPU || want_index == SB_VK_IGPU) {
            /* Asked for a kind this machine does not have. A skip with a
             * reason, not a silent fall back to a different device -- a row
             * that said "cpu" while measuring a GPU would be worse than no
             * row. */
            fprintf(stderr, "vulkan: no %s device here\n",
                    want_index == SB_VK_CPU ? "software" : "integrated");
            exit(3);
        }
        chosen = 0;
    }
    c->phys = devs[chosen];

    VkPhysicalDeviceProperties pr;
    vkGetPhysicalDeviceProperties(c->phys, &pr);
    snprintf(c->device_name, sizeof c->device_name, "%s", pr.deviceName);
    free(devs);

    uint32_t qn = 0;
    vkGetPhysicalDeviceQueueFamilyProperties(c->phys, &qn, NULL);
    VkQueueFamilyProperties *qs = calloc(qn, sizeof *qs);
    vkGetPhysicalDeviceQueueFamilyProperties(c->phys, &qn, qs);
    c->qfam = UINT32_MAX;
    for (uint32_t i = 0; i < qn; i++)
        if (qs[i].queueFlags & VK_QUEUE_COMPUTE_BIT) { c->qfam = i; break; }
    free(qs);
    if (c->qfam == UINT32_MAX) {
        fprintf(stderr, "vulkan: no compute queue family\n");
        exit(3);
    }
}

static VkShaderModule load_spirv(vk_ctx *c, const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "vulkan: cannot open %s\n", path); exit(3); }
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    uint32_t *code = malloc((size_t)n);
    if (fread(code, 1, (size_t)n, f) != (size_t)n) {
        fprintf(stderr, "vulkan: short read on %s\n", path);
        exit(3);
    }
    fclose(f);
    VkShaderModuleCreateInfo si = {
        .sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
        .codeSize = (size_t)n, .pCode = code,
    };
    VkShaderModule m;
    VK_CHECK(vkCreateShaderModule(c->dev, &si, NULL, &m));
    free(code);
    return m;
}

/* ---- pipelines ---------------------------------------------------------- */

static void build_pipelines(vk_ctx *c, const char *spv_dir) {
    /* Nine storage buffers, one binding each, in the order the shaders
     * declare them. */
    VkDescriptorSetLayoutBinding bind[B_COUNT];
    for (int i = 0; i < B_COUNT; i++) {
        bind[i] = (VkDescriptorSetLayoutBinding){
            .binding = (uint32_t)i,
            .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .descriptorCount = 1,
            .stageFlags = VK_SHADER_STAGE_COMPUTE_BIT,
        };
    }
    VkDescriptorSetLayoutCreateInfo dli = {
        .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        .bindingCount = B_COUNT, .pBindings = bind,
    };
    VK_CHECK(vkCreateDescriptorSetLayout(c->dev, &dli, NULL, &c->dsl));

    VkPushConstantRange pcr = {
        .stageFlags = VK_SHADER_STAGE_COMPUTE_BIT,
        .offset = 0, .size = sizeof(vk_push),
    };
    VkPipelineLayoutCreateInfo pli = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .setLayoutCount = 1, .pSetLayouts = &c->dsl,
        .pushConstantRangeCount = 1, .pPushConstantRanges = &pcr,
    };
    VK_CHECK(vkCreatePipelineLayout(c->dev, &pli, NULL, &c->playout));

    /* Two sets, not one rewritten per tick. The diffusion shader always reads
     * binding 0 and writes binding 1, so the buffer swap is a choice of which
     * set to bind -- the same trick the GL host plays with glBindBufferBase,
     * and it keeps the per-tick work to three dispatches and two barriers. */
    VkDescriptorPoolSize ps = {
        .type = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
        .descriptorCount = B_COUNT * 2,
    };
    VkDescriptorPoolCreateInfo dpi = {
        .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
        .maxSets = 2, .poolSizeCount = 1, .pPoolSizes = &ps,
    };
    VK_CHECK(vkCreateDescriptorPool(c->dev, &dpi, NULL, &c->dpool));

    VkDescriptorSetLayout layouts[2] = { c->dsl, c->dsl };
    VkDescriptorSetAllocateInfo dai = {
        .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
        .descriptorPool = c->dpool, .descriptorSetCount = 2,
        .pSetLayouts = layouts,
    };
    VK_CHECK(vkAllocateDescriptorSets(c->dev, &dai, c->dsets));

    for (int parity = 0; parity < 2; parity++) {
        VkDescriptorBufferInfo bi[B_COUNT];
        VkWriteDescriptorSet w[B_COUNT];
        for (int i = 0; i < B_COUNT; i++) {
            int src = i;
            if (i == B_GRID)    src = parity ? B_SCRATCH : B_GRID;
            if (i == B_SCRATCH) src = parity ? B_GRID : B_SCRATCH;
            bi[i] = (VkDescriptorBufferInfo){
                .buffer = c->bufs[src].buf, .offset = 0, .range = VK_WHOLE_SIZE,
            };
            w[i] = (VkWriteDescriptorSet){
                .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                .dstSet = c->dsets[parity], .dstBinding = (uint32_t)i,
                .descriptorCount = 1,
                .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
                .pBufferInfo = &bi[i],
            };
        }
        vkUpdateDescriptorSets(c->dev, B_COUNT, w, 0, NULL);
    }

    static const char *names[3] = { "agents.spv", "merge.spv", "diffuse.spv" };
    for (int k = 0; k < 3; k++) {
        char path[512];
        snprintf(path, sizeof path, "%s/%s", spv_dir, names[k]);
        VkShaderModule m = load_spirv(c, path);
        VkComputePipelineCreateInfo ci = {
            .sType = VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
            .stage = {
                .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
                .stage = VK_SHADER_STAGE_COMPUTE_BIT,
                .module = m, .pName = "main",
            },
            .layout = c->playout,
        };
        VK_CHECK(vkCreateComputePipelines(c->dev, VK_NULL_HANDLE, 1, &ci, NULL,
                                          &c->pipe[k]));
        vkDestroyShaderModule(c->dev, m, NULL);
    }
}

/* Everything written by one dispatch is read by the next, so the barrier is
 * the same shape three times: shader writes before shader reads, over all
 * buffers. A finer barrier would be a claim about which shader touches which
 * buffer, and the point of this host is not to be clever. */
static void barrier(VkCommandBuffer cmd) {
    VkMemoryBarrier mb = {
        .sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER,
        .srcAccessMask = VK_ACCESS_SHADER_WRITE_BIT,
        .dstAccessMask = VK_ACCESS_SHADER_READ_BIT | VK_ACCESS_SHADER_WRITE_BIT,
    };
    vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
                         VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, 0,
                         1, &mb, 0, NULL, 0, NULL);
}

static void record_tick(vk_ctx *c, int parity, const vk_push *pc,
                        uint32_t ag_gx, uint32_t ag_gy,
                        uint32_t cl_gx, uint32_t cl_gy) {
    VkCommandBufferBeginInfo bi = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
    };
    VK_CHECK(vkBeginCommandBuffer(c->cmd, &bi));
    vkCmdBindDescriptorSets(c->cmd, VK_PIPELINE_BIND_POINT_COMPUTE, c->playout,
                            0, 1, &c->dsets[parity], 0, NULL);
    vkCmdPushConstants(c->cmd, c->playout, VK_SHADER_STAGE_COMPUTE_BIT, 0,
                       sizeof *pc, pc);

    vkCmdBindPipeline(c->cmd, VK_PIPELINE_BIND_POINT_COMPUTE, c->pipe[0]);
    vkCmdDispatch(c->cmd, ag_gx, ag_gy, 1);
    barrier(c->cmd);
    vkCmdBindPipeline(c->cmd, VK_PIPELINE_BIND_POINT_COMPUTE, c->pipe[1]);
    vkCmdDispatch(c->cmd, cl_gx, cl_gy, 1);
    barrier(c->cmd);
    vkCmdBindPipeline(c->cmd, VK_PIPELINE_BIND_POINT_COMPUTE, c->pipe[2]);
    vkCmdDispatch(c->cmd, cl_gx, cl_gy, 1);
    barrier(c->cmd);

    VK_CHECK(vkEndCommandBuffer(c->cmd));
}

/* ---- host arithmetic, identical to the OpenGL host ---------------------- */

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
    s[2] ^= s[0]; s[3] ^= s[1]; s[1] ^= s[2]; s[0] ^= s[3]; s[2] ^= t;
    s[3] = rotl32(s[3], 11);
    return r;
}
static float rnd01(uint32_t u) { return (float)(u >> 8) / 16777216.0f; }
static uint32_t fnv(uint32_t h, uint32_t w) { return (h ^ w) * 0x01000193u; }

static double now_ms(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (double)t.tv_sec * 1e3 + (double)t.tv_nsec / 1e6;
}
static int cmpd(const void *a, const void *b) {
    const double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}

/* Two dimensions when one is not enough, same rule as the GL host. */
static int split_groups(uint32_t groups, uint32_t maxx, uint32_t maxy,
                        uint32_t *gx, uint32_t *gy) {
    if (groups == 0) { *gx = *gy = 1; return 0; }
    if (groups <= maxx) { *gx = groups; *gy = 1; return 0; }
    *gx = maxx;
    *gy = (groups + maxx - 1) / maxx;
    return (*gy <= maxy) ? 0 : -1;
}

typedef struct {
    uint32_t width, height, agents, ticks, warmup, seed;
    float sensor_dist, step, deposit, decay;
    uint32_t ss, rs;
    const char *preset;
    int json;
    int device_index;
    const char *spv_dir;
} opts;

static void usage(FILE *f, const char *argv0) {
    fprintf(f,
        "usage: %s [options]   (slimebench SPEC-1, Vulkan compute)\n"
        "  --preset NAME        tiny|small|medium|large|huge\n"
        "  --width N --height N --agents N --ticks N --warmup N --seed N\n"
        "  --update deferred    the only mode a GPU can express (SPEC-1 5.5)\n"
        "  --device KIND        cpu|integrated|discrete, or an index; a kind\n"
        "                       rather than an index, because an index depends\n"
        "                       on which ICDs happen to be installed\n"
        "  --list-devices       print what Vulkan can see here and exit\n"
        "  --spv DIR            compiled shaders; default is `spv` beside the\n"
        "                       executable\n"
        "  --json  -h, --help\n", argv0);
}

int main(int argc, char **argv) {
    opts o = { 1024, 1024, 262144, 1000, 0, 12345,
               9.0f, 1.0f, 10.0f, 0.94f, 144, 144, "custom", 0, -1, NULL };
    int list_only = 0;

#define NEED()                                                              \
    (++i < argc ? argv[i]                                                   \
                : (fprintf(stderr, "error: %s requires a value\n", argv[i-1]), \
                   exit(2), ""))

    for (int i = 1; i < argc; i++) {
        const char *a = argv[i];
        if (!strcmp(a, "-h") || !strcmp(a, "--help")) { usage(stdout, argv[0]); return 0; }
        else if (!strcmp(a, "--preset")) {
            const char *p = NEED();
            if (!strcmp(p, "tiny"))        { o.width=512;  o.height=512;  o.agents=65536;    o.ticks=1000; }
            else if (!strcmp(p, "small"))  { o.width=1024; o.height=1024; o.agents=262144;   o.ticks=1000; }
            else if (!strcmp(p, "medium")) { o.width=2048; o.height=2048; o.agents=1048576;  o.ticks=1000; }
            else if (!strcmp(p, "large"))  { o.width=4096; o.height=4096; o.agents=4194304;  o.ticks=500; }
            else if (!strcmp(p, "huge"))   { o.width=8192; o.height=8192; o.agents=16777216; o.ticks=100; }
            else { fprintf(stderr, "error: unknown preset '%s'\n", p); return 2; }
            o.preset = p;
        }
        else if (!strcmp(a, "--width"))  { o.width  = (uint32_t)strtoul(NEED(), NULL, 10); o.preset = "custom"; }
        else if (!strcmp(a, "--height")) { o.height = (uint32_t)strtoul(NEED(), NULL, 10); o.preset = "custom"; }
        else if (!strcmp(a, "--agents")) { o.agents = (uint32_t)strtoul(NEED(), NULL, 10); o.preset = "custom"; }
        else if (!strcmp(a, "--ticks"))  { o.ticks  = (uint32_t)strtoul(NEED(), NULL, 10); }
        else if (!strcmp(a, "--warmup")) { o.warmup = (uint32_t)strtoul(NEED(), NULL, 10); }
        else if (!strcmp(a, "--seed"))   { o.seed   = (uint32_t)strtoul(NEED(), NULL, 10); }
        else if (!strcmp(a, "--sensor-steps")) { o.ss = (uint32_t)strtoul(NEED(), NULL, 10); }
        else if (!strcmp(a, "--rot-steps"))    { o.rs = (uint32_t)strtoul(NEED(), NULL, 10); }
        else if (!strcmp(a, "--sensor-dist"))  { o.sensor_dist = strtof(NEED(), NULL); }
        else if (!strcmp(a, "--step"))         { o.step = strtof(NEED(), NULL); }
        else if (!strcmp(a, "--deposit"))      { o.deposit = strtof(NEED(), NULL); }
        else if (!strcmp(a, "--decay"))        { o.decay = strtof(NEED(), NULL); }
        else if (!strcmp(a, "--device")) {
            const char *d = NEED();
            if (!strcmp(d, "cpu")) o.device_index = SB_VK_CPU;
            else if (!strcmp(d, "integrated")) o.device_index = SB_VK_IGPU;
            else if (!strcmp(d, "discrete")) o.device_index = SB_VK_ANY;
            else o.device_index = (int)strtol(d, NULL, 10);
        }
        else if (!strcmp(a, "--spv"))          { o.spv_dir = NEED(); }
        else if (!strcmp(a, "--list-devices")) { list_only = 1; }
        else if (!strcmp(a, "--json"))         { o.json = 1; }
        else if (!strcmp(a, "--headless"))     { /* accepted, always true */ }
        else if (!strcmp(a, "--threads"))      { (void)NEED(); }
        else if (!strcmp(a, "--update")) {
            const char *m = NEED();
            if (strcmp(m, "deferred") != 0) {
                /* Same refusal as every other GPU host: `serial` lets an agent
                 * read a deposit its predecessor made this tick, and no
                 * dispatch expresses that (SPEC-1 5.5). */
                fprintf(stderr, "error: --update serial is not expressible on a "
                                "GPU; deferred only (SPEC-1 5.5)\n");
                return 2;
            }
        }
        else { fprintf(stderr, "error: unknown argument '%s'\n", a);
               usage(stderr, argv[0]); return 2; }
    }
#undef NEED

    vk_ctx c;
    memset(&c, 0, sizeof c);

    VkApplicationInfo ai = {
        .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
        .pApplicationName = "slimebench", .apiVersion = VK_API_VERSION_1_1,
    };
    VkInstanceCreateInfo ii = {
        .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &ai,
    };
    VK_CHECK(vkCreateInstance(&ii, NULL, &c.inst));

    if (list_only) {
        uint32_t n = 0;
        vkEnumeratePhysicalDevices(c.inst, &n, NULL);
        VkPhysicalDevice *d = calloc(n, sizeof *d);
        vkEnumeratePhysicalDevices(c.inst, &n, d);
        for (uint32_t i = 0; i < n; i++) {
            VkPhysicalDeviceProperties pr;
            vkGetPhysicalDeviceProperties(d[i], &pr);
            static const char *kind[] = { "other", "integrated", "discrete",
                                          "virtual", "cpu" };
            printf("  %u  %-11s %s\n", i,
                   pr.deviceType <= 4 ? kind[pr.deviceType] : "?", pr.deviceName);
        }
        free(d);
        vkDestroyInstance(c.inst, NULL);
        return 0;
    }

    pick_device(&c, o.device_index);

    const float prio = 1.0f;
    VkDeviceQueueCreateInfo qi = {
        .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
        .queueFamilyIndex = c.qfam, .queueCount = 1, .pQueuePriorities = &prio,
    };
    VkDeviceCreateInfo di = {
        .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
        .queueCreateInfoCount = 1, .pQueueCreateInfos = &qi,
    };
    VK_CHECK(vkCreateDevice(c.phys, &di, NULL, &c.dev));
    vkGetDeviceQueue(c.dev, c.qfam, 0, &c.queue);

    VkCommandPoolCreateInfo cpi = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
        .queueFamilyIndex = c.qfam,
    };
    VK_CHECK(vkCreateCommandPool(c.dev, &cpi, NULL, &c.pool));
    VkCommandBufferAllocateInfo cbi = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = c.pool, .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandBufferCount = 1,
    };
    VK_CHECK(vkAllocateCommandBuffers(c.dev, &cbi, &c.cmd));

    /* ---- host init, SPEC-1 section 3.3 ---------------------------------- */
    const size_t cells = (size_t)o.width * o.height;
    uint32_t log2w = 0;
    while ((1u << log2w) < o.width) log2w++;

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
    uint32_t *depcount = calloc(cells, 4);

    /* ---- buffers -------------------------------------------------------- */
    const VkBufferUsageFlags SSBO = VK_BUFFER_USAGE_STORAGE_BUFFER_BIT
                                  | VK_BUFFER_USAGE_TRANSFER_SRC_BIT
                                  | VK_BUFFER_USAGE_TRANSFER_DST_BIT;
    const VkMemoryPropertyFlags LOCAL = VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT;
    const VkMemoryPropertyFlags HOST = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT
                                     | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;

    VkDeviceSize biggest = cells * 4;
    if ((VkDeviceSize)o.agents * 16 > biggest) biggest = (VkDeviceSize)o.agents * 16;
    buffer_create(&c, &c.staging, biggest,
                  VK_BUFFER_USAGE_TRANSFER_SRC_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT,
                  HOST);

    /* Device-local, with one staging buffer for the upload at the start and
     * the read-back at the end. Nothing crosses the bus per tick, which is the
     * whole point of measuring a GPU. */
    buffer_create(&c, &c.bufs[B_GRID],    cells * 4,            SSBO, LOCAL);
    buffer_create(&c, &c.bufs[B_SCRATCH], cells * 4,            SSBO, LOCAL);
    buffer_create(&c, &c.bufs[B_DEP],     cells * 4,            SSBO, LOCAL);
    buffer_create(&c, &c.bufs[B_AX],      (VkDeviceSize)o.agents * 4,  SSBO, LOCAL);
    buffer_create(&c, &c.bufs[B_AY],      (VkDeviceSize)o.agents * 4,  SSBO, LOCAL);
    buffer_create(&c, &c.bufs[B_ADIR],    (VkDeviceSize)o.agents * 4,  SSBO, LOCAL);
    buffer_create(&c, &c.bufs[B_ARNG],    (VkDeviceSize)o.agents * 16, SSBO, LOCAL);
    buffer_create(&c, &c.bufs[B_COS],     SB_NDIR * 4,          SSBO, LOCAL);
    buffer_create(&c, &c.bufs[B_SIN],     SB_NDIR * 4,          SSBO, LOCAL);

    upload(&c, &c.bufs[B_GRID], grid, cells * 4);
    upload(&c, &c.bufs[B_DEP], depcount, cells * 4);
    upload(&c, &c.bufs[B_AX], ax, (size_t)o.agents * 4);
    upload(&c, &c.bufs[B_AY], ay, (size_t)o.agents * 4);
    upload(&c, &c.bufs[B_ADIR], adir, (size_t)o.agents * 4);
    upload(&c, &c.bufs[B_ARNG], arng, (size_t)o.agents * 16);
    upload(&c, &c.bufs[B_COS], costab, SB_NDIR * 4);
    upload(&c, &c.bufs[B_SIN], sintab, SB_NDIR * 4);

    /* Beside the executable unless told otherwise. A path relative to the
     * working directory would depend on who invoked us, and the harness
     * spawns targets from the repository root rather than from their own
     * directory -- which is how the first version of this looked for the
     * shaders in the wrong place. */
    char spv[1024];
    if (o.spv_dir) {
        snprintf(spv, sizeof spv, "%s", o.spv_dir);
    } else {
        snprintf(spv, sizeof spv, "%s", argv[0]);
        char *slash = strrchr(spv, '/');
        if (slash) slash[1] = '\0'; else spv[0] = '\0';
        strncat(spv, "spv", sizeof spv - strlen(spv) - 1);
    }
    build_pipelines(&c, spv);

    VkPhysicalDeviceProperties props;
    vkGetPhysicalDeviceProperties(c.phys, &props);
    uint32_t ag_gx, ag_gy, cl_gx, cl_gy;
    if (split_groups((o.agents + 63u) / 64u,
                     props.limits.maxComputeWorkGroupCount[0],
                     props.limits.maxComputeWorkGroupCount[1],
                     &ag_gx, &ag_gy) != 0 ||
        split_groups((uint32_t)((cells + 63u) / 64u),
                     props.limits.maxComputeWorkGroupCount[0],
                     props.limits.maxComputeWorkGroupCount[1],
                     &cl_gx, &cl_gy) != 0) {
        fprintf(stderr, "error: preset too large for this device's work-group "
                        "limits\n");
        return 1;
    }

    vk_push pc = {
        .width = o.width, .height = o.height, .log2w = log2w,
        .xmask = o.width - 1u, .ymask = o.height - 1u,
        .agents = o.agents, .cells = (uint32_t)cells,
        .ss = (int32_t)o.ss, .rs = (int32_t)o.rs, .ndir = SB_NDIR,
        .sensor_dist = o.sensor_dist, .step = o.step,
        .deposit = o.deposit, .decay = o.decay,
    };

    /* ---- run ------------------------------------------------------------ */
    int parity = 0;
    for (uint32_t t = 0; t < o.warmup; t++) {
        record_tick(&c, parity, &pc, ag_gx, ag_gy, cl_gx, cl_gy);
        submit_and_wait(&c);
        parity ^= 1;
    }

    double *tick_ms = malloc((o.ticks ? o.ticks : 1) * sizeof(double));
    const double t_start = now_ms();
    for (uint32_t t = 0; t < o.ticks; t++) {
        const double a = now_ms();
        record_tick(&c, parity, &pc, ag_gx, ag_gy, cl_gx, cl_gy);
        submit_and_wait(&c);
        parity ^= 1;
        tick_ms[t] = now_ms() - a;
    }
    const double ms_total = now_ms() - t_start;

    /* ---- read back and hash --------------------------------------------- */
    const int live = parity ? B_SCRATCH : B_GRID;
    download(&c, &c.bufs[live], grid, cells * 4);
    download(&c, &c.bufs[B_AX], ax, (size_t)o.agents * 4);
    download(&c, &c.bufs[B_AY], ay, (size_t)o.agents * 4);
    download(&c, &c.bufs[B_ADIR], adir, (size_t)o.agents * 4);

    uint32_t gh = 0x811C9DC5u, agh = 0x811C9DC5u, dh = 0x811C9DC5u;
    for (size_t i = 0; i < cells; i++) {
        uint32_t w; memcpy(&w, &grid[i], 4); gh = fnv(gh, w);
    }
    for (uint32_t i = 0; i < o.agents; i++) {
        uint32_t w;
        memcpy(&w, &ax[i], 4); agh = fnv(agh, w);
        memcpy(&w, &ay[i], 4); agh = fnv(agh, w);
        agh = fnv(agh, adir[i]);
    }
    for (int d = 0; d < SB_NDIR; d++) dh = fnv(dh, SB_COS_BITS[d]);
    for (int d = 0; d < SB_NDIR; d++) dh = fnv(dh, SB_SIN_BITS[d]);

    const size_t n = o.ticks;
    double median = 0, p99 = 0, mean = 0;
    if (n) {
        double *srt = malloc(n * sizeof(double));
        memcpy(srt, tick_ms, n * sizeof(double));
        qsort(srt, n, sizeof(double), cmpd);
        median = srt[n / 2];
        size_t pi = (size_t)((double)n * 0.99); if (pi >= n) pi = n - 1;
        p99 = srt[pi];
        for (size_t i = 0; i < n; i++) mean += tick_ms[i];
        mean /= (double)n;
        free(srt);
    }

    if (o.json) {
        printf("{\"schema\":1,\"impl\":\"vulkan\",\"backend\":\"vulkan\",\"class\":\"G\","
               "\"preset\":\"%s\",\"variant\":\"%s\","
               "\"width\":%u,\"height\":%u,\"agents\":%u,\"ticks\":%zu,\"seed\":%u,"
               "\"update\":\"deferred\",\"threads\":1,"
               "\"grid_hash\":\"0x%08X\",\"agent_hash\":\"0x%08X\",\"dirtable_hash\":\"0x%08X\","
               "\"ms_total\":%.4f,\"ms_agents\":0.0,\"ms_diffuse\":0.0,"
               "\"ms_per_tick_mean\":%.6f,\"ms_per_tick_median\":%.6f,\"ms_per_tick_p99\":%.6f,"
               "\"maups\":%.4f,\"mcups\":%.4f}\n",
               o.preset, c.device_name,
               o.width, o.height, o.agents, n, o.seed,
               gh, agh, dh, ms_total, mean, median, p99,
               ms_total > 0 ? (double)o.agents * (double)n / ms_total / 1000.0 : 0.0,
               ms_total > 0 ? (double)cells * (double)n / ms_total / 1000.0 : 0.0);
    } else {
        printf("%s %ux%u agents=%u ticks=%u update=deferred\n",
               o.preset, o.width, o.height, o.agents, o.ticks);
        printf("  device     %s\n", c.device_name);
        printf("  grid_hash  0x%08X\n", gh);
        printf("  agent_hash 0x%08X\n", agh);
        printf("  total      %.2f ms  (%.4f ms/tick)\n",
               ms_total, o.ticks ? ms_total / o.ticks : 0.0);
    }

    for (int i = 0; i < B_COUNT; i++) buffer_free(&c, &c.bufs[i]);
    buffer_free(&c, &c.staging);
    for (int k = 0; k < 3; k++) vkDestroyPipeline(c.dev, c.pipe[k], NULL);
    vkDestroyPipelineLayout(c.dev, c.playout, NULL);
    vkDestroyDescriptorPool(c.dev, c.dpool, NULL);
    vkDestroyDescriptorSetLayout(c.dev, c.dsl, NULL);
    vkDestroyCommandPool(c.dev, c.pool, NULL);
    vkDestroyDevice(c.dev, NULL);
    vkDestroyInstance(c.inst, NULL);
    free(tick_ms); free(grid); free(ax); free(ay); free(adir); free(arng);
    free(depcount);
    return 0;
}
