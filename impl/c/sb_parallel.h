/* slimebench -- multi-threaded tick (SPEC-1 section 5.6, benchmark class P).
 *
 * Only valid with SB_UPDATE_DEFERRED. The serial update mode is inherently
 * sequential: an agent's deposit changes what the next agent senses.
 */
#ifndef SB_PARALLEL_H
#define SB_PARALLEL_H

#include "sb_core.h"

typedef struct sb_pool sb_pool;

/* Phase breakdown, enabled with SLIMEBENCH_PHASE_STATS=1. */
enum {
    SB_PH_AGENTS = 0,
    SB_PH_PREFIX,
    SB_PH_SCATTER,
    SB_PH_DEPOSIT,
    SB_PH_MERGE,
    SB_PH_DIFFUSE,
    SB_PH_COUNT
};

/* Writes a one-line summary to stderr; no-op unless stats were enabled. */
void sb_pool_report_phases(const sb_pool *p, uint32_t ticks);

/* Creates cfg.threads workers, alive until sb_pool_destroy. Returns NULL if
 * the configuration cannot be parallelised (message on stderr). */
sb_pool *sb_pool_create(sb_sim *s);
void sb_pool_destroy(sb_pool *p);

/* One full tick, same semantics as sb_tick(). */
void sb_tick_parallel(sb_sim *s, sb_pool *p);

/* Bytes of scratch the chosen reduction strategy holds. Reported so the
 * private/binned memory trade-off shows up in the results rather than only
 * in RSS. */
size_t sb_pool_scratch_bytes(const sb_pool *p);

#endif /* SB_PARALLEL_H */
