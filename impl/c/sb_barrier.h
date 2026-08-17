/* Phase barrier for the threaded tick, in two flavours.
 *
 * `pthread_barrier_wait` is the obvious choice and is what this started with.
 * But SLIMEBENCH_PHASE_STATS=1 put barriers at 35% of the tick at 16 threads
 * and 53% at 32, with phase bodies as short as 0.05 ms. At that granularity a
 * futex round trip -- park, wake 31 threads, reschedule -- is plausibly the
 * dominant cost, and spinning should win.
 *
 * So both exist and are selectable at runtime:
 *
 *   SLIMEBENCH_BARRIER=spin      pause-spin, then sched_yield
 *   SLIMEBENCH_BARRIER=hybrid    pause-spin, then park on a futex
 *   SLIMEBENCH_BARRIER=pthread   pthread_barrier_wait  (default)
 *
 * Plain `spin` is included because it is what one writes first, and because
 * its failure mode is worth recording: at 32 threads on a 16-core part every
 * logical CPU is either working or spinning, and the yield loop steals
 * execution resources from the SMT sibling that is still doing real work.
 *
 * The choice cannot affect results -- a barrier is a barrier -- so it is an
 * environment knob rather than part of the CLI contract in SPEC-1 section 10.
 */
#ifndef SB_BARRIER_H
#define SB_BARRIER_H

#include <linux/futex.h>
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdint.h>
#include <sys/syscall.h>
#include <unistd.h>

#if defined(__x86_64__) || defined(__i386__)
#include <immintrin.h>
#define SB_CPU_RELAX() _mm_pause()
#else
#define SB_CPU_RELAX() ((void)0)
#endif

typedef enum {
    SB_BARRIER_PTHREAD = 0,
    SB_BARRIER_SPIN = 1,     /* spin, then sched_yield */
    SB_BARRIER_HYBRID = 2,   /* spin, then park on a futex */
} sb_barrier_kind;

typedef struct {
    sb_barrier_kind kind;
    uint32_t n;

    pthread_barrier_t pb;

    /* Sense-reversing counter. `generation` is the sense: a waiter releases
     * when it changes, which is why a late arrival cannot slip through the
     * next barrier -- it is still watching the old value. */
    _Atomic uint32_t count;
    _Atomic uint32_t generation;
    /* Pause iterations before falling back to sched_yield(). Long enough to
     * cover a short phase, short enough not to burn a core when a thread is
     * genuinely behind. */
    uint32_t spin_limit;
} sb_barrier;

static inline void sb_barrier_init(sb_barrier *b, uint32_t n, sb_barrier_kind kind) {
    b->kind = kind;
    b->n = n;
    atomic_init(&b->count, 0u);
    atomic_init(&b->generation, 0u);
    b->spin_limit = 4000;
    if (kind == SB_BARRIER_PTHREAD) pthread_barrier_init(&b->pb, NULL, n);
}

static inline void sb_barrier_destroy(sb_barrier *b) {
    if (b->kind == SB_BARRIER_PTHREAD) pthread_barrier_destroy(&b->pb);
}

static inline void sb_futex_wake_all(_Atomic uint32_t *addr) {
    syscall(SYS_futex, (uint32_t *)addr, FUTEX_WAKE_PRIVATE, INT32_MAX, NULL, NULL, 0);
}

static inline void sb_futex_wait(_Atomic uint32_t *addr, uint32_t expect) {
    syscall(SYS_futex, (uint32_t *)addr, FUTEX_WAIT_PRIVATE, expect, NULL, NULL, 0);
}

static inline void sb_barrier_wait(sb_barrier *b) {
    if (b->kind == SB_BARRIER_PTHREAD) {
        pthread_barrier_wait(&b->pb);
        return;
    }

    const uint32_t gen = atomic_load_explicit(&b->generation, memory_order_acquire);
    if (atomic_fetch_add_explicit(&b->count, 1u, memory_order_acq_rel) + 1u == b->n) {
        /* Last in: reset the counter, then flip the sense. The release on
         * `generation` publishes every write the other threads made before
         * they arrived. */
        atomic_store_explicit(&b->count, 0u, memory_order_relaxed);
        atomic_fetch_add_explicit(&b->generation, 1u, memory_order_release);
        if (b->kind == SB_BARRIER_HYBRID) sb_futex_wake_all(&b->generation);
        return;
    }

    uint32_t spins = 0;
    while (atomic_load_explicit(&b->generation, memory_order_acquire) == gen) {
        if (++spins < b->spin_limit) {
            SB_CPU_RELAX();
            continue;
        }
        if (b->kind == SB_BARRIER_HYBRID) {
            /* Park. FUTEX_WAIT rechecks the value under the kernel lock, so
             * the release between the load above and here is not a lost
             * wakeup -- it just returns EAGAIN and the loop re-tests. */
            sb_futex_wait(&b->generation, gen);
        } else {
            sched_yield();
        }
        spins = 0;
    }
}

#endif /* SB_BARRIER_H */
