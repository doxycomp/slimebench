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
    VkDescriptorSet dset;
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
        if (pr.deviceType == VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU) { chosen = (int)i; break; }
        if (chosen < 0 && pr.deviceType != VK_PHYSICAL_DEVICE_TYPE_CPU) chosen = (int)i;
    }
    if (chosen < 0) chosen = 0;
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

int main(void) {
    fprintf(stderr, "impl/vulkan: host skeleton -- see slimebench_vk.c\n");
    return 0;
}
