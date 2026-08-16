// slimebench -- multi-threaded tick (SPEC-1 section 5.6, benchmark class P).
//
// Same algorithm as the C version in impl/c/sb_parallel.c, expressed with
// std::jthread and std::barrier instead of pthreads. Comparing the two is
// part of the point: identical strategy, different amount of ceremony.
//
// Only valid with Update::Deferred.

#pragma once

#include <memory>

#include "sim.hpp"

namespace sb {

class Pool {
  public:
    // Returns nullptr if the configuration cannot be parallelised
    // (message already on stderr).
    static std::unique_ptr<Pool> create(Sim& sim);
    ~Pool();

    Pool(const Pool&) = delete;
    Pool& operator=(const Pool&) = delete;

    void tick();

    // Bytes the chosen reduction strategy holds, so the private/binned memory
    // trade-off shows up in the results and not only in RSS.
    std::size_t scratchBytes() const noexcept;

  private:
    struct Impl;
    explicit Pool(std::unique_ptr<Impl> impl);
    std::unique_ptr<Impl> impl_;
};

}  // namespace sb
