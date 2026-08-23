/* slimebench -- verifying a machine against a known-correct result.
 *
 * ## What this is for
 *
 * Every other mode here asks how fast something is. This one asks whether the
 * machine computed it correctly, and it can ask that because SPEC-1 makes the
 * answer machine-independent: the same configuration produces the same bits on
 * any conforming implementation, on any CPU, on any GPU. So a chain of hashes
 * recorded once on a machine believed to be healthy is a reference for every
 * other machine, forever.
 *
 * That is the difference from a memory tester. memtest86 checks patterns
 * against themselves -- it knows what it wrote, so it can tell whether it came
 * back. It cannot tell you whether the arithmetic between the write and the
 * read was right. This can: every float that ever enters the grid goes through
 * a multiply, an add, a division by twelve and a gather, and all of it lands in
 * the checksum.
 *
 * What the workload happens to exercise, without being designed to:
 *
 *   - 16 to 256 MiB of grid, read nine times and written once per cell per
 *     tick -- streaming bandwidth, in both directions.
 *   - three scattered reads per agent per tick, a million agents, over that
 *     whole footprint -- the access pattern that finds an unstable memory
 *     controller where a sequential sweep does not.
 *   - `--threads 32` puts every core on it at once.
 *   - `--agent-tile` adds a full permutation of 26 bytes per agent every
 *     other tick, which is a different kind of traffic again.
 *   - class G runs the identical computation in VRAM.
 *
 * ## Localising a mismatch
 *
 * A single grid hash says the machine is wrong and nothing else. So the chain
 * also carries SB_VERIFY_BLOCKS hashes, one per contiguous slice of the grid.
 * A mismatch names the slice, and a slice is a byte range at a known offset in
 * one allocation -- which is as close to "this DIMM, this address" as a
 * userspace program can honestly get.
 *
 * A tick number matters as much as an address. A fault that appears at tick 3
 * and one that appears at tick 900 are different problems: the first is
 * reproducible and probably logic, the second is heat or drift.
 *
 * ## What it cannot do
 *
 * It cannot distinguish RAM from cache from the FPU -- it only says the result
 * is wrong. It cannot see a fault in memory the simulation never touches. And
 * a deterministic fault that happens to affect the reference machine too would
 * be baked into the chain, which is why the chain in spec/ was produced on a
 * machine that passes the conformance gate against fourteen independent
 * implementations.
 */
#ifndef SB_VERIFY_H
#define SB_VERIFY_H

#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "sb_core.h"

/* Enough to name a region, few enough that a line stays readable. At 2048x2048
 * one block is 256 KiB. */
#define SB_VERIFY_BLOCKS 64

/* FNV-32 of each contiguous slice of the grid, in the same byte order as
 * sb_hash_grid. Separate from the normative grid hash rather than combined
 * with it: SPEC-1 6.2 fixes how the grid hash is computed, and this must not
 * change that. */
static inline void sb_hash_blocks(const sb_sim *s, uint32_t out[SB_VERIFY_BLOCKS]) {
    const size_t cells = (size_t)s->cfg.width * s->cfg.height;
    const size_t per = (cells + SB_VERIFY_BLOCKS - 1u) / SB_VERIFY_BLOCKS;
    for (int b = 0; b < SB_VERIFY_BLOCKS; b++) {
        const size_t lo = (size_t)b * per;
        const size_t hi = (lo + per < cells) ? lo + per : cells;
        uint32_t h = 0x811C9DC5u;
        for (size_t i = lo; i < hi; i++) {
            uint32_t bits;
            memcpy(&bits, &s->grid[i], sizeof bits);
            h = (h ^ bits) * 0x01000193u;
        }
        out[b] = h;
    }
}

/* One checkpoint, as written to and read from the chain file. */
typedef struct {
    uint32_t tick;
    uint32_t grid;
    uint32_t agents;
    uint32_t blocks[SB_VERIFY_BLOCKS];
} sb_checkpoint;

static inline void sb_checkpoint_take(const sb_sim *s, uint32_t tick,
                                      sb_checkpoint *c) {
    c->tick = tick;
    c->grid = sb_hash_grid(s);
    c->agents = sb_hash_agents(s);
    sb_hash_blocks(s, c->blocks);
}

/* The header names the configuration, because a chain is only a reference for
 * the configuration it was recorded from. Verifying against the wrong one is
 * the mistake this line exists to make impossible. */
static inline void sb_chain_header(const sb_config *cfg, char *out, size_t n) {
    snprintf(out, n, "%ux%u agents=%u seed=%u update=%s sensor=%g step=%g "
                     "deposit=%g decay=%g rot=%u sens=%u",
             cfg->width, cfg->height, cfg->agents, cfg->seed,
             cfg->update == SB_UPDATE_DEFERRED ? "deferred" : "serial",
             (double)cfg->sensor_dist, (double)cfg->step,
             (double)cfg->deposit, (double)cfg->decay,
             cfg->rot_steps, cfg->sensor_steps);
}

static inline void sb_checkpoint_write(FILE *f, const sb_checkpoint *c) {
    fprintf(f, "%u %08X %08X", c->tick, c->grid, c->agents);
    for (int b = 0; b < SB_VERIFY_BLOCKS; b++) fprintf(f, " %08X", c->blocks[b]);
    fputc('\n', f);
}

/* Reads the next checkpoint line. Returns 0 at end of file, 1 on success,
 * -1 on a malformed line -- which is a broken chain file, not a bad machine,
 * and has to be said differently. */
static inline int sb_checkpoint_read(FILE *f, sb_checkpoint *c) {
    int ch;
    do {
        ch = fgetc(f);
        if (ch == '#') { while (ch != '\n' && ch != EOF) ch = fgetc(f); }
    } while (ch == '\n' || ch == '#');
    if (ch == EOF) return 0;
    ungetc(ch, f);

    if (fscanf(f, "%u %8X %8X", &c->tick, &c->grid, &c->agents) != 3) return -1;
    for (int b = 0; b < SB_VERIFY_BLOCKS; b++)
        if (fscanf(f, " %8X", &c->blocks[b]) != 1) return -1;
    return 1;
}

/* Compares and reports. Returns the number of mismatching blocks, or -1 when
 * the grid hash matches (nothing to report). */
static inline int sb_checkpoint_diff(const sb_sim *s, const sb_checkpoint *want,
                                     const sb_checkpoint *got, FILE *err) {
    if (want->grid == got->grid && want->agents == got->agents) return -1;

    const size_t cells = (size_t)s->cfg.width * s->cfg.height;
    const size_t per = (cells + SB_VERIFY_BLOCKS - 1u) / SB_VERIFY_BLOCKS;

    fprintf(err, "MISMATCH at tick %u\n", got->tick);
    if (want->grid != got->grid)
        fprintf(err, "  grid   expected 0x%08X, got 0x%08X\n",
                want->grid, got->grid);
    if (want->agents != got->agents)
        fprintf(err, "  agents expected 0x%08X, got 0x%08X\n",
                want->agents, got->agents);

    int bad = 0;
    for (int b = 0; b < SB_VERIFY_BLOCKS; b++) {
        if (want->blocks[b] == got->blocks[b]) continue;
        bad++;
        const size_t lo = (size_t)b * per;
        const size_t hi = (lo + per < cells) ? lo + per : cells;
        fprintf(err, "  block %2d  cells %zu..%zu  rows %zu..%zu  "
                     "grid+%zu..%zu bytes\n",
                b, lo, hi - 1,
                lo / s->cfg.width, (hi - 1) / s->cfg.width,
                lo * sizeof(float), (hi - 1) * sizeof(float));
    }
    if (bad == 0)
        fprintf(err, "  every block hash matches, so the divergence is in the "
                     "agents rather than the grid\n");
    else if (bad == SB_VERIFY_BLOCKS)
        fprintf(err, "  every block differs -- the whole grid is wrong, which "
                     "is a different configuration or a broken build rather "
                     "than a hardware fault\n");
    return bad;
}

#endif /* SB_VERIFY_H */
