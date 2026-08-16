#include "parallel.hpp"

#include <barrier>
#include <condition_variable>
#include <cstdio>
#include <mutex>
#include <thread>
#include <vector>

#include "agent.hpp"

namespace sb {
namespace {

// Contiguous split of [0, n) into `parts`; part `i` is [lo, hi).
struct Range {
    std::uint32_t lo, hi;
};

constexpr Range split(std::uint32_t n, std::uint32_t parts, std::uint32_t i) noexcept {
    const std::uint32_t base = n / parts;
    const std::uint32_t rem = n % parts;
    const std::uint32_t lo = i * base + (i < rem ? i : rem);
    return Range{lo, lo + base + (i < rem ? 1u : 0u)};
}

}  // namespace

struct Pool::Impl {
    Sim* sim = nullptr;
    std::uint32_t nthreads = 0;

    std::vector<std::jthread> threads;
    std::barrier<> phase;

    std::mutex mu;
    std::condition_variable cv_go, cv_done;
    std::uint64_t generation = 0;
    std::uint32_t pending = 0;
    bool shutdown = false;

    // Reduce::Private
    std::vector<std::vector<float>> priv;

    // Reduce::Binned
    std::vector<std::uint32_t> aidx;     // agents
    std::vector<std::uint32_t> sorted;   // agents
    std::vector<std::uint32_t> counts;   // nthreads * nthreads
    std::vector<std::uint32_t> offsets;  // nthreads * nthreads
    std::vector<std::uint16_t> ybucket;  // height

    std::size_t scratch_bytes = 0;

    explicit Impl(std::uint32_t t) : nthreads(t), phase(static_cast<std::ptrdiff_t>(t)) {}

    // Row block owning cell `idx`. Table lookup rather than arithmetic: this
    // runs twice per agent per tick and a 64-bit divide there costs more than
    // the rest of the step.
    std::uint32_t bucketOf(std::uint32_t idx) const noexcept {
        return ybucket[idx >> sim->log2w()];
    }

    void agentsPrivate(std::uint32_t tid) {
        const Sim::Ctx k = sim->makeCtx();
        const float deposit = sim->cfg().deposit;
        float* dep = priv[tid].data();
        const auto r = split(sim->cfg().agents, nthreads, tid);
        for (std::uint32_t i = r.lo; i < r.hi; ++i) {
            const std::uint32_t idx = sim->agentStep(k, i);
            dep[idx] = dep[idx] + deposit;
        }
    }

    void mergePrivate(std::uint32_t tid) {
        auto& grid = sim->gridMut();
        const auto r = split(static_cast<std::uint32_t>(grid.size()), nthreads, tid);
        // Fixed thread order, so the result is reproducible for this thread
        // count. It is NOT in general the serial grouping -- SPEC-1 5.6.
        for (std::uint32_t i = r.lo; i < r.hi; ++i) {
            float acc = priv[0][i];
            priv[0][i] = 0.0f;
            for (std::uint32_t t = 1; t < nthreads; ++t) {
                acc = acc + priv[t][i];
                priv[t][i] = 0.0f;
            }
            grid[i] = grid[i] + acc;
        }
    }

    void agentsBinned(std::uint32_t tid) {
        const Sim::Ctx k = sim->makeCtx();
        const auto r = split(sim->cfg().agents, nthreads, tid);
        std::uint32_t* cnt = &counts[std::size_t{tid} * nthreads];
        std::fill(cnt, cnt + nthreads, 0u);
        for (std::uint32_t i = r.lo; i < r.hi; ++i) {
            const std::uint32_t idx = sim->agentStep(k, i);
            aidx[i] = idx;
            ++cnt[bucketOf(idx)];
        }
    }

    // Prefix sum over (bucket, thread) in that order. Each thread owns a
    // contiguous ascending agent range, so walking threads in order inside a
    // bucket lays the agents down in ascending global index -- which is what
    // makes the deposit chain identical to the serial one.
    void prefixBinned() {
        std::uint32_t running = 0;
        for (std::uint32_t b = 0; b < nthreads; ++b) {
            for (std::uint32_t w = 0; w < nthreads; ++w) {
                offsets[std::size_t{w} * nthreads + b] = running;
                running += counts[std::size_t{w} * nthreads + b];
            }
        }
    }

    void scatterBinned(std::uint32_t tid) {
        const auto r = split(sim->cfg().agents, nthreads, tid);
        std::uint32_t* off = &offsets[std::size_t{tid} * nthreads];
        for (std::uint32_t i = r.lo; i < r.hi; ++i) {
            sorted[off[bucketOf(aidx[i])]++] = i;
        }
    }

    void depositBinned(std::uint32_t tid) {
        const float deposit = sim->cfg().deposit;
        std::uint32_t begin = 0;
        for (std::uint32_t b = 0; b < tid; ++b)
            for (std::uint32_t w = 0; w < nthreads; ++w)
                begin += counts[std::size_t{w} * nthreads + b];
        std::uint32_t end = begin;
        for (std::uint32_t w = 0; w < nthreads; ++w)
            end += counts[std::size_t{w} * nthreads + tid];

        float* dep = sim->dep().data();
        for (std::uint32_t j = begin; j < end; ++j) {
            const std::uint32_t idx = aidx[sorted[j]];
            dep[idx] = dep[idx] + deposit;
        }
    }

    void mergeBinned(std::uint32_t tid) {
        auto& grid = sim->gridMut();
        auto& dep = sim->dep();
        const auto r = split(static_cast<std::uint32_t>(grid.size()), nthreads, tid);
        for (std::uint32_t i = r.lo; i < r.hi; ++i) {
            grid[i] = grid[i] + dep[i];
            dep[i] = 0.0f;
        }
    }

    void diffuse(std::uint32_t tid) {
        const auto r = split(sim->cfg().height, nthreads, tid);
        sim->diffuseRows(r.lo, r.hi);
    }

    void runTick(std::uint32_t tid) {
        if (sim->cfg().reduce == Reduce::Binned) {
            agentsBinned(tid);
            phase.arrive_and_wait();
            if (tid == 0) prefixBinned();
            phase.arrive_and_wait();
            scatterBinned(tid);
            phase.arrive_and_wait();
            depositBinned(tid);
            phase.arrive_and_wait();
            mergeBinned(tid);
        } else {
            agentsPrivate(tid);
            phase.arrive_and_wait();
            mergePrivate(tid);
        }
        phase.arrive_and_wait();
        diffuse(tid);
    }

    void worker(std::uint32_t tid) {
        std::uint64_t seen = 0;
        for (;;) {
            {
                std::unique_lock lk(mu);
                cv_go.wait(lk, [&] { return shutdown || generation != seen; });
                if (shutdown) return;
                seen = generation;
            }
            runTick(tid);
            {
                std::lock_guard lk(mu);
                if (--pending == 0) cv_done.notify_one();
            }
        }
    }
};

Pool::Pool(std::unique_ptr<Impl> impl) : impl_(std::move(impl)) {}

std::unique_ptr<Pool> Pool::create(Sim& sim) {
    if (sim.cfg().update != Update::Deferred) {
        std::fprintf(stderr,
            "error: --threads > 1 requires --update deferred.\n"
            "       SPEC-1 'serial' makes an agent's deposit visible to the\n"
            "       next agent in the same tick, which is a sequential\n"
            "       dependency; see SPEC-1 section 5.5.\n");
        return nullptr;
    }
    if (sim.cfg().threads < 2) return nullptr;

    const std::uint32_t t = sim.cfg().threads;
    auto impl = std::make_unique<Impl>(t);
    impl->sim = &sim;

    const std::size_t cells = std::size_t{sim.cfg().width} * sim.cfg().height;
    const std::size_t n = sim.cfg().agents;

    if (sim.cfg().reduce == Reduce::Private) {
        impl->priv.assign(t, std::vector<float>(cells, 0.0f));
        impl->scratch_bytes = std::size_t{t} * cells * sizeof(float);
    } else {
        impl->aidx.resize(n);
        impl->sorted.resize(n);
        impl->counts.assign(std::size_t{t} * t, 0u);
        impl->offsets.assign(std::size_t{t} * t, 0u);
        impl->ybucket.resize(sim.cfg().height);
        // Same split as diffuse(), so a thread's deposits land in rows it
        // already touches.
        for (std::uint32_t b = 0; b < t; ++b) {
            const auto r = split(sim.cfg().height, t, b);
            for (std::uint32_t y = r.lo; y < r.hi; ++y)
                impl->ybucket[y] = static_cast<std::uint16_t>(b);
        }
        impl->scratch_bytes = 2 * n * sizeof(std::uint32_t) +
                              2 * std::size_t{t} * t * sizeof(std::uint32_t) +
                              std::size_t{sim.cfg().height} * sizeof(std::uint16_t);
    }

    Impl* raw = impl.get();
    impl->threads.reserve(t);
    for (std::uint32_t i = 0; i < t; ++i)
        impl->threads.emplace_back([raw, i] { raw->worker(i); });

    return std::unique_ptr<Pool>(new Pool(std::move(impl)));
}

Pool::~Pool() {
    if (!impl_) return;
    {
        std::lock_guard lk(impl_->mu);
        impl_->shutdown = true;
    }
    impl_->cv_go.notify_all();
    // std::jthread joins on destruction.
}

std::size_t Pool::scratchBytes() const noexcept {
    return impl_ ? impl_->scratch_bytes : 0;
}

void Pool::tick() {
    Impl& p = *impl_;
    const std::uint64_t t0 = nowNs();
    {
        std::unique_lock lk(p.mu);
        p.pending = p.nthreads;
        ++p.generation;
        p.cv_go.notify_all();
        p.cv_done.wait(lk, [&] { return p.pending == 0; });
    }
    p.sim->swapBuffers();

    // The phases interleave across threads, so an agent/diffusion split like
    // the serial path reports would be meaningless. Class P reports wall time.
    p.sim->ns_agents += nowNs() - t0;
}

}  // namespace sb
