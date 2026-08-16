/* slimebench -- multi-threaded tick (SPEC-1 section 5.6, benchmark class P).
 *
 * pthreads rather than OpenMP: it builds with both gcc and clang without an
 * extra package (clang needs libomp-dev, which gcc does not), and the
 * determinism argument below is easier to review when the synchronisation is
 * spelled out instead of implied by a pragma.
 *
 * The pool is created once and reused. Spawning 32 threads per tick would cost
 * roughly 1 ms against a 4 ms tick.
 */

#include "sb_parallel.h"

#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "sb_agent.h"

typedef struct sb_worker {
    sb_pool *pool;
    uint32_t tid;
    pthread_t thread;
} sb_worker;

struct sb_pool {
    sb_sim *sim;
    uint32_t nthreads;

    pthread_t *threads;
    sb_worker *workers;

    pthread_mutex_t mu;
    pthread_cond_t cv_go;
    pthread_cond_t cv_done;
    uint64_t generation;
    uint32_t pending;
    int shutdown;

    pthread_barrier_t phase;

    /* SB_REDUCE_PRIVATE: one full-grid deposit buffer per thread. */
    float **priv;

    /* SB_REDUCE_BINNED: target cell per agent, plus a stable counting sort of
     * the agent indices by row block. */
    uint32_t *aidx;     /* agents            */
    uint32_t *sorted;   /* agents            */
    uint32_t *counts;   /* nthreads*nthreads */
    uint32_t *offsets;  /* nthreads*nthreads */
    uint16_t *ybucket;  /* height -- row to owning thread */

    size_t scratch_bytes;
};

/* Contiguous split of [0, n) into `parts`; part `i` is [lo, hi). */
static inline void split(uint32_t n, uint32_t parts, uint32_t i,
                         uint32_t *lo, uint32_t *hi) {
    const uint32_t base = n / parts;
    const uint32_t rem = n % parts;
    *lo = i * base + (i < rem ? i : rem);
    *hi = *lo + base + (i < rem ? 1u : 0u);
}

/* Row block owning cell index `idx`, i.e. which thread applies its deposit.
 * Table lookup rather than arithmetic: this runs twice per agent per tick, and
 * a 64-bit division there is more expensive than the whole rest of the step.
 * The table is at most `height` entries, so it stays in L1. */
static inline uint32_t bucket_of(const sb_pool *p, uint32_t idx) {
    return p->ybucket[idx >> p->sim->cfg.log2w];
}

/* ---- the three phases, run by every worker ------------------------------ */

static void phase_agents_private(sb_pool *p, uint32_t tid) {
    sb_sim *s = p->sim;
    const sb_agent_ctx k = sb_agent_ctx_make(s);
    const float deposit = s->cfg.deposit;
    float *dep = p->priv[tid];

    uint32_t lo, hi;
    split(s->cfg.agents, p->nthreads, tid, &lo, &hi);
    for (uint32_t i = lo; i < hi; i++) {
        const uint32_t idx = sb_agent_step(&k, s, i);
        dep[idx] = dep[idx] + deposit;
    }
}

static void phase_merge_private(sb_pool *p, uint32_t tid) {
    sb_sim *s = p->sim;
    const size_t cells = (size_t)s->cfg.width * s->cfg.height;
    uint32_t lo, hi;
    split((uint32_t)cells, p->nthreads, tid, &lo, &hi);

    /* Fixed thread order, so the result is reproducible for this thread
     * count. It is NOT in general the same grouping as the serial chain --
     * see SPEC-1 section 5.6. */
    for (uint32_t i = lo; i < hi; i++) {
        float acc = p->priv[0][i];
        p->priv[0][i] = 0.0f;
        for (uint32_t t = 1; t < p->nthreads; t++) {
            acc = acc + p->priv[t][i];
            p->priv[t][i] = 0.0f;
        }
        s->grid[i] = s->grid[i] + acc;
    }
}

static void phase_agents_binned(sb_pool *p, uint32_t tid) {
    sb_sim *s = p->sim;
    const sb_agent_ctx k = sb_agent_ctx_make(s);

    uint32_t lo, hi;
    split(s->cfg.agents, p->nthreads, tid, &lo, &hi);

    uint32_t *cnt = &p->counts[(size_t)tid * p->nthreads];
    memset(cnt, 0, (size_t)p->nthreads * sizeof(uint32_t));

    for (uint32_t i = lo; i < hi; i++) {
        const uint32_t idx = sb_agent_step(&k, s, i);
        p->aidx[i] = idx;
        cnt[bucket_of(p, idx)]++;
    }
}

/* Prefix sum over (bucket, thread) in that order. Because each thread owns a
 * contiguous, ascending agent range, walking threads in order inside a bucket
 * lays the agents down in ascending global index -- which is what makes the
 * deposit chain identical to the serial one. */
static void phase_prefix_binned(sb_pool *p) {
    const uint32_t t = p->nthreads;
    uint32_t running = 0;
    for (uint32_t b = 0; b < t; b++) {
        for (uint32_t w = 0; w < t; w++) {
            p->offsets[(size_t)w * t + b] = running;
            running += p->counts[(size_t)w * t + b];
        }
    }
}

static void phase_scatter_binned(sb_pool *p, uint32_t tid) {
    sb_sim *s = p->sim;
    uint32_t lo, hi;
    split(s->cfg.agents, p->nthreads, tid, &lo, &hi);

    uint32_t *off = &p->offsets[(size_t)tid * p->nthreads];
    for (uint32_t i = lo; i < hi; i++) {
        p->sorted[off[bucket_of(p, p->aidx[i])]++] = i;
    }
}

static void phase_deposit_binned(sb_pool *p, uint32_t tid) {
    sb_sim *s = p->sim;
    const uint32_t t = p->nthreads;
    const float deposit = s->cfg.deposit;

    /* Bucket `tid` occupies sorted[begin, end); begin is the offset the prefix
     * sum handed to thread 0 for this bucket, before scatter advanced it. */
    uint32_t begin = 0;
    for (uint32_t b = 0; b < tid; b++)
        for (uint32_t w = 0; w < t; w++) begin += p->counts[(size_t)w * t + b];
    uint32_t end = begin;
    for (uint32_t w = 0; w < t; w++) end += p->counts[(size_t)w * t + tid];

    float *dep = s->dep;
    for (uint32_t j = begin; j < end; j++) {
        const uint32_t idx = p->aidx[p->sorted[j]];
        dep[idx] = dep[idx] + deposit;
    }
}

static void phase_merge_binned(sb_pool *p, uint32_t tid) {
    sb_sim *s = p->sim;
    const size_t cells = (size_t)s->cfg.width * s->cfg.height;
    uint32_t lo, hi;
    split((uint32_t)cells, p->nthreads, tid, &lo, &hi);
    for (uint32_t i = lo; i < hi; i++) {
        s->grid[i] = s->grid[i] + s->dep[i];
        s->dep[i] = 0.0f;
    }
}

static void phase_diffuse(sb_pool *p, uint32_t tid) {
    sb_sim *s = p->sim;
    uint32_t lo, hi;
    split(s->cfg.height, p->nthreads, tid, &lo, &hi);
    sb_diffuse_rows(s, s->grid, s->scratch, lo, hi);
}

/* ---- worker loop -------------------------------------------------------- */

static void run_tick(sb_pool *p, uint32_t tid) {
    const int binned = (p->sim->cfg.reduce == SB_REDUCE_BINNED);

    if (binned) {
        phase_agents_binned(p, tid);
        pthread_barrier_wait(&p->phase);
        if (tid == 0) phase_prefix_binned(p);
        pthread_barrier_wait(&p->phase);
        phase_scatter_binned(p, tid);
        pthread_barrier_wait(&p->phase);
        phase_deposit_binned(p, tid);
        pthread_barrier_wait(&p->phase);
        phase_merge_binned(p, tid);
    } else {
        phase_agents_private(p, tid);
        pthread_barrier_wait(&p->phase);
        phase_merge_private(p, tid);
    }

    pthread_barrier_wait(&p->phase);
    phase_diffuse(p, tid);
}

static void *worker_main(void *arg) {
    sb_worker *w = (sb_worker *)arg;
    sb_pool *p = w->pool;
    uint64_t seen = 0;

    for (;;) {
        pthread_mutex_lock(&p->mu);
        while (!p->shutdown && p->generation == seen)
            pthread_cond_wait(&p->cv_go, &p->mu);
        if (p->shutdown) {
            pthread_mutex_unlock(&p->mu);
            return NULL;
        }
        seen = p->generation;
        pthread_mutex_unlock(&p->mu);

        run_tick(p, w->tid);

        pthread_mutex_lock(&p->mu);
        if (--p->pending == 0) pthread_cond_signal(&p->cv_done);
        pthread_mutex_unlock(&p->mu);
    }
}

/* ---- lifecycle ---------------------------------------------------------- */

sb_pool *sb_pool_create(sb_sim *s) {
    if (s->cfg.update != SB_UPDATE_DEFERRED) {
        fprintf(stderr,
            "error: --threads > 1 requires --update deferred.\n"
            "       SPEC-1 'serial' makes an agent's deposit visible to the\n"
            "       next agent in the same tick, which is a sequential\n"
            "       dependency; see SPEC-1 section 5.5.\n");
        return NULL;
    }
    if (s->cfg.threads < 2) return NULL;

    sb_pool *p = (sb_pool *)calloc(1, sizeof *p);
    if (!p) return NULL;
    p->sim = s;
    p->nthreads = s->cfg.threads;

    const size_t cells = (size_t)s->cfg.width * s->cfg.height;
    const size_t n = s->cfg.agents;
    const uint32_t t = p->nthreads;

    if (s->cfg.reduce == SB_REDUCE_PRIVATE) {
        p->priv = (float **)calloc(t, sizeof(float *));
        if (!p->priv) goto fail;
        for (uint32_t i = 0; i < t; i++) {
            p->priv[i] = (float *)calloc(cells, sizeof(float));
            if (!p->priv[i]) goto fail;
        }
        p->scratch_bytes = (size_t)t * cells * sizeof(float);
    } else {
        p->aidx = (uint32_t *)malloc(n * sizeof(uint32_t));
        p->sorted = (uint32_t *)malloc(n * sizeof(uint32_t));
        p->counts = (uint32_t *)calloc((size_t)t * t, sizeof(uint32_t));
        p->offsets = (uint32_t *)calloc((size_t)t * t, sizeof(uint32_t));
        p->ybucket = (uint16_t *)malloc(s->cfg.height * sizeof(uint16_t));
        if (!p->aidx || !p->sorted || !p->counts || !p->offsets || !p->ybucket)
            goto fail;

        /* Row -> owning thread, using the same split as phase_diffuse so a
         * thread's deposits land in rows it already touches. */
        for (uint32_t b = 0; b < t; b++) {
            uint32_t lo, hi;
            split(s->cfg.height, t, b, &lo, &hi);
            for (uint32_t y = lo; y < hi; y++) p->ybucket[y] = (uint16_t)b;
        }

        p->scratch_bytes = 2 * n * sizeof(uint32_t) +
                           2 * (size_t)t * t * sizeof(uint32_t) +
                           (size_t)s->cfg.height * sizeof(uint16_t);
    }

    pthread_mutex_init(&p->mu, NULL);
    pthread_cond_init(&p->cv_go, NULL);
    pthread_cond_init(&p->cv_done, NULL);
    pthread_barrier_init(&p->phase, NULL, t);

    p->threads = (pthread_t *)calloc(t, sizeof(pthread_t));
    p->workers = (sb_worker *)calloc(t, sizeof(sb_worker));
    if (!p->threads || !p->workers) goto fail;

    for (uint32_t i = 0; i < t; i++) {
        p->workers[i].pool = p;
        p->workers[i].tid = i;
        if (pthread_create(&p->threads[i], NULL, worker_main, &p->workers[i]) != 0) {
            fprintf(stderr, "error: could not create thread %u\n", i);
            goto fail;
        }
    }
    return p;

fail:
    sb_pool_destroy(p);
    return NULL;
}

void sb_pool_destroy(sb_pool *p) {
    if (!p) return;

    if (p->threads) {
        pthread_mutex_lock(&p->mu);
        p->shutdown = 1;
        pthread_cond_broadcast(&p->cv_go);
        pthread_mutex_unlock(&p->mu);
        for (uint32_t i = 0; i < p->nthreads; i++)
            if (p->threads[i]) pthread_join(p->threads[i], NULL);
    }

    if (p->priv) {
        for (uint32_t i = 0; i < p->nthreads; i++) free(p->priv[i]);
        free(p->priv);
    }
    free(p->aidx);
    free(p->sorted);
    free(p->counts);
    free(p->offsets);
    free(p->ybucket);
    free(p->threads);
    free(p->workers);

    pthread_barrier_destroy(&p->phase);
    pthread_cond_destroy(&p->cv_done);
    pthread_cond_destroy(&p->cv_go);
    pthread_mutex_destroy(&p->mu);
    free(p);
}

size_t sb_pool_scratch_bytes(const sb_pool *p) {
    return p ? p->scratch_bytes : 0;
}

void sb_tick_parallel(sb_sim *s, sb_pool *p) {
    const uint64_t t0 = sb_now_ns();

    pthread_mutex_lock(&p->mu);
    p->pending = p->nthreads;
    p->generation++;
    pthread_cond_broadcast(&p->cv_go);
    while (p->pending != 0) pthread_cond_wait(&p->cv_done, &p->mu);
    pthread_mutex_unlock(&p->mu);

    float *tmp = s->grid;
    s->grid = s->scratch;
    s->scratch = tmp;

    /* The phases interleave across threads, so splitting the tick into agent
     * and diffusion time the way the serial path does would be meaningless
     * here. Class P reports wall time only. */
    s->ns_agents += sb_now_ns() - t0;
}
