#!/usr/bin/env python3
"""slimebench -- class P for the numpy target (SPEC-1 section 5.6).

Processes, not threads. CPython 3.12 has a GIL, so `threading` would serialise
the very loops this is meant to spread out -- numpy releases the GIL inside
large ufunc calls, but the agent pass is a chain of dozens of small ones with
Python-level glue between them, and that glue holds the lock. `multiprocessing`
over one `shared_memory` block is the only honest way to use more than one core
here, and the plumbing it costs is itself part of the answer.

Both reduction strategies from SPEC-1 5.6, the same phase order and the same
deposit order as the C reference, so `binned` is bit-identical to the
single-process run.

## What is different from the threaded ports

* **The buffers must be laid out by hand.** In C, Rust and Haskell the workers
  simply see the parent's arrays. Here every array that a worker touches has to
  live in a `SharedMemory` block with an agreed offset, and the numpy views are
  rebuilt on the far side of the fork.
* **The barrier is an OS object.** `multiprocessing.Barrier` is a semaphore
  plus a condition variable in shared memory; a round trip is tens of
  microseconds rather than the hundreds of nanoseconds a futex barrier costs.
  That would dominate a C tick. It does not dominate here, because a numpy tick
  at `medium` is tens of milliseconds -- the slowest implementation can afford
  the most expensive barrier.
* **`fork` is required.** With `spawn` each worker would re-import numpy and
  re-run `_init_state`, which is a sequential SplitMix32 over four million
  cells. The module refuses to run under `spawn` rather than take that cost
  silently.
"""

from __future__ import annotations

import multiprocessing as mp
import os
import sys
import time
from multiprocessing import shared_memory

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from slimebench import common  # noqa: E402
import slimebench_numpy as sbn  # noqa: E402


def _split(n: int, parts: int, i: int) -> tuple[int, int]:
    """Contiguous split of [0, n) into `parts`; part `i` is [lo, hi).

    Identical to the C reference's `split`, deliberately: the partition is what
    makes `binned` reproduce the serial deposit order.
    """
    base, rem = divmod(n, parts)
    lo = i * base + min(i, rem)
    return lo, lo + base + (1 if i < rem else 0)


class Layout:
    """Offsets into the one shared block, so both sides agree by construction."""

    def __init__(self, cfg: common.Config, threads: int, reduce: str):
        self.cells = cfg.width * cfg.height
        self.agents = cfg.agents
        self.height = cfg.height
        self.threads = threads
        self.reduce = reduce
        self.off: dict[str, int] = {}

        p = 0

        def put(name: str, nbytes: int) -> None:
            nonlocal p
            p = (p + 63) & ~63          # keep each array on its own cache line
            self.off[name] = p
            p += nbytes

        put("grid", self.cells * 4)
        put("scratch", self.cells * 4)
        put("dep", self.cells * 4)
        put("ax", self.agents * 4)
        put("ay", self.agents * 4)
        put("adir", self.agents * 4)
        put("arng", self.agents * 16)

        if reduce == "binned":
            put("aidx", self.agents * 4)
            put("sorted", self.agents * 4)
            put("counts", threads * threads * 4)
            put("offsets", threads * threads * 4)
            put("ybucket", self.height * 4)
            put("rowcnt", threads * self.height * 4)
            put("rowsum", self.height * 4)
        else:
            put("priv", threads * self.cells * 4)

        self.nbytes = (p + 63) & ~63

    def views(self, shm: shared_memory.SharedMemory) -> dict[str, np.ndarray]:
        b = shm.buf
        o, c, n, h, t = self.off, self.cells, self.agents, self.height, self.threads

        def f32(name: str, count: int) -> np.ndarray:
            return np.ndarray((count,), dtype=np.float32, buffer=b, offset=o[name])

        def i32(name: str, count: int) -> np.ndarray:
            return np.ndarray((count,), dtype=np.int32, buffer=b, offset=o[name])

        v = {
            "grid": f32("grid", c),
            "scratch": f32("scratch", c),
            "dep": f32("dep", c),
            "ax": f32("ax", n),
            "ay": f32("ay", n),
            "adir": i32("adir", n),
            "arng": np.ndarray((n, 4), dtype=np.uint32, buffer=b, offset=o["arng"]),
        }
        if self.reduce == "binned":
            v.update({
                "aidx": i32("aidx", n),
                "sorted": i32("sorted", n),
                "counts": i32("counts", t * t),
                "offsets": i32("offsets", t * t),
                "ybucket": i32("ybucket", h),
                "rowcnt": i32("rowcnt", t * h),
                "rowsum": i32("rowsum", h),
            })
        else:
            v["priv"] = f32("priv", t * c)
        return v


class Worker:
    """One tick, run identically by the parent (as rank 0) and every child."""

    def __init__(self, sim, v, layout, tid, barrier, reduce, adaptive):
        self.sim = sim
        self.v = v
        self.L = layout
        self.tid = tid
        self.t = layout.threads
        self.barrier = barrier
        self.reduce = reduce
        self.adaptive = adaptive
        self.deposit = np.float32(sim.cfg.deposit)

    # -- binned ------------------------------------------------------------

    def agents_binned(self) -> None:
        lo, hi = _split(self.L.agents, self.t, self.tid)
        self.sim.agent_range(lo, hi, self.v["aidx"])

        idx = self.v["aidx"][lo:hi]
        rows = idx >> self.sim.log2w
        bucket = self.v["ybucket"][rows]
        base = self.tid * self.t
        self.v["counts"][base:base + self.t] = np.bincount(bucket, minlength=self.t)
        if self.adaptive:
            rb = self.tid * self.L.height
            self.v["rowcnt"][rb:rb + self.L.height] = np.bincount(
                rows, minlength=self.L.height)

    def prefix_binned(self) -> None:
        """Prefix sum over (bucket, thread) in that order.

        Each worker owns a contiguous ascending agent range, so walking workers
        in order inside a bucket lays the agents down in ascending global index
        -- which is what makes the deposit chain identical to the serial one.
        """
        t = self.t
        counts = self.v["counts"].reshape(t, t)          # [worker][bucket]
        # Column-major cumulative sum: bucket outer, worker inner.
        flat = counts.T.reshape(-1)
        starts = np.concatenate(([0], np.cumsum(flat[:-1]))).astype(np.int32)
        self.v["offsets"][:] = starts.reshape(t, t).T.reshape(-1)

    def scatter_binned(self) -> None:
        lo, hi = _split(self.L.agents, self.t, self.tid)
        idx = self.v["aidx"][lo:hi]
        bucket = self.v["ybucket"][idx >> self.sim.log2w]
        base = self.tid * self.t

        # A stable counting sort: order within a bucket must stay ascending in
        # the global agent index, which argsort(kind="stable") guarantees.
        order = np.argsort(bucket, kind="stable")
        dest = np.empty(hi - lo, dtype=np.int32)
        off = self.v["offsets"][base:base + self.t].copy()
        run_starts = np.concatenate(([0], np.cumsum(np.bincount(bucket, minlength=self.t))))
        for b in range(self.t):
            a, z = run_starts[b], run_starts[b + 1]
            if z > a:
                dest[a:z] = np.arange(off[b], off[b] + (z - a), dtype=np.int32)
        self.v["sorted"][dest] = (order + lo).astype(np.int32)

    def deposit_binned(self) -> None:
        t = self.t
        counts = self.v["counts"].reshape(t, t)
        begin = int(counts[:, :self.tid].sum())
        end = begin + int(counts[:, self.tid].sum())
        if end <= begin:
            return
        agents = self.v["sorted"][begin:end]
        cells = self.v["aidx"][agents]
        # Unbuffered and in index order, matching SPEC-1's per-agent chain.
        np.add.at(self.v["dep"], cells, self.deposit)

    def merge_binned(self) -> None:
        ylo, yhi = _split(self.L.height, self.t, self.tid)
        self.sim.merge_rows(ylo, yhi)
        if self.adaptive:
            rc = self.v["rowcnt"].reshape(self.t, self.L.height)
            self.v["rowsum"][ylo:yhi] = rc[:, ylo:yhi].sum(axis=0)

    def rebalance(self) -> None:
        """Row boundaries by deposit count rather than by row count.

        Cannot change the result: the partition decides *which* worker applies
        a deposit, never the order deposits hit a cell.
        """
        t = self.t
        rowsum = self.v["rowsum"]
        total = int(rowsum.sum())
        if total == 0:
            return
        # Row y goes to the bucket its *preceding* rows have filled, so row 0
        # always lands in bucket 0 and the assignment is monotone -- the same
        # shape as the C reference's assign-then-advance loop. The exact
        # partition is not normative: it decides which worker applies a
        # deposit, never the order deposits hit a cell.
        acc = np.cumsum(rowsum.astype(np.int64))
        prev = np.concatenate(([0], acc[:-1]))
        b = np.minimum((prev * t) // total, t - 1).astype(np.int32)
        self.v["ybucket"][:] = b

    # -- private -----------------------------------------------------------

    def agents_private(self) -> None:
        lo, hi = _split(self.L.agents, self.t, self.tid)
        priv = self.v["priv"]
        c = self.L.cells
        mine = priv[self.tid * c:(self.tid + 1) * c]
        saved = self.sim.dep
        self.sim.dep = mine
        try:
            self.sim.agent_range(lo, hi)
        finally:
            self.sim.dep = saved

    def merge_private(self) -> None:
        """Fixed worker order, so the result is reproducible for this worker
        count. It is NOT in general the same grouping as the serial chain --
        SPEC-1 5.6."""
        lo, hi = _split(self.L.cells, self.t, self.tid)
        priv = self.v["priv"]
        c = self.L.cells
        acc = priv[lo:hi].copy()
        priv[lo:hi] = np.float32(0.0)
        for k in range(1, self.t):
            seg = priv[k * c + lo:k * c + hi]
            acc += seg
            seg[:] = np.float32(0.0)
        self.v["grid"][lo:hi] += acc

    # -- the tick ----------------------------------------------------------

    def run_tick(self) -> None:
        if self.reduce == "binned":
            self.agents_binned()
            self.barrier.wait()
            if self.tid == 0:
                self.prefix_binned()
            self.barrier.wait()
            self.scatter_binned()
            self.barrier.wait()
            self.deposit_binned()
            self.barrier.wait()
            self.merge_binned()
            self.barrier.wait()
            if self.tid == 0 and self.adaptive:
                self.rebalance()
        else:
            self.agents_private()
            self.barrier.wait()
            self.merge_private()
            self.barrier.wait()

        ylo, yhi = _split(self.L.height, self.t, self.tid)
        self.sim.diffuse_rows(ylo, yhi)
        self.barrier.wait()

        # Each process swaps its own two views. They name the same two regions
        # of the shared block, so this is one exchange performed N times rather
        # than a shared write needing a sync point.
        self.sim.swap_buffers()
        self.v["grid"], self.v["scratch"] = self.v["scratch"], self.v["grid"]


def _child(shm_name, layout, cfg, tid, barrier, reduce, adaptive, ticks):
    shm = shared_memory.SharedMemory(name=shm_name)
    try:
        v = layout.views(shm)
        sim = sbn.Sim(cfg, bufs=v, do_init=False)
        w = Worker(sim, v, layout, tid, barrier, reduce, adaptive)
        for _ in range(ticks):
            w.run_tick()
    finally:
        del v
        shm.close()


def run_parallel(cfg: common.Config, threads: int, reduce: str,
                 warmup: int, ticks: int):
    """Returns (sim, ms_total, tick_ms). Exits with a message on refusal."""
    if cfg.update != "deferred":
        sys.stderr.write(
            "error: --threads > 1 requires --update deferred.\n"
            "       SPEC-1 'serial' makes an agent's deposit visible to the\n"
            "       next agent in the same tick, which is a sequential\n"
            "       dependency; see SPEC-1 section 5.5.\n")
        sys.exit(2)
    if mp.get_start_method(allow_none=True) not in (None, "fork"):
        sys.stderr.write("error: this target needs the 'fork' start method.\n")
        sys.exit(2)
    try:
        mp.set_start_method("fork")
    except RuntimeError:
        pass

    L = Layout(cfg, threads, reduce)
    shm = shared_memory.SharedMemory(create=True, size=L.nbytes)
    try:
        v = L.views(shm)
        # Seed once, in the parent: SPEC-1 3.3 is sequential and the children
        # attach to the result.
        sim = sbn.Sim(cfg, bufs=v, do_init=True)

        if reduce == "binned":
            # Row -> owning worker, same split as the diffusion pass so a
            # worker's deposits land in rows it already touches.
            for b in range(threads):
                lo, hi = _split(cfg.height, threads, b)
                v["ybucket"][lo:hi] = b

        adaptive = os.environ.get("SLIMEBENCH_NO_REBALANCE") is None
        barrier = mp.Barrier(threads)
        total = warmup + ticks

        procs = []
        for tid in range(1, threads):
            p = mp.Process(target=_child,
                           args=(shm.name, L, cfg, tid, barrier, reduce,
                                 adaptive, total),
                           daemon=True)
            p.start()
            procs.append(p)

        me = Worker(sim, v, L, 0, barrier, reduce, adaptive)
        for _ in range(warmup):
            me.run_tick()
        sim.ns_agents = 0
        sim.ns_diffuse = 0

        tick_ms = []
        t0 = time.perf_counter_ns()
        for _ in range(ticks):
            a = time.perf_counter_ns()
            me.run_tick()
            tick_ms.append((time.perf_counter_ns() - a) / 1e6)
        ms_total = (time.perf_counter_ns() - t0) / 1e6

        for p in procs:
            p.join()

        # The phases interleave across processes, so an agent/diffuse split
        # would be meaningless here. Class P reports wall time.
        sim.ns_agents = int(ms_total * 1e6)
        sim.ns_diffuse = 0

        # Copy out before the block goes away; the caller still hashes.
        sim.grid = np.array(sim.grid)
        sim.ax = np.array(sim.ax)
        sim.ay = np.array(sim.ay)
        sim.adir = np.array(sim.adir)
        return sim, ms_total, tick_ms
    finally:
        try:
            del v
        except Exception:
            pass
        shm.close()
        shm.unlink()
