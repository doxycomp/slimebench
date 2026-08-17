# slimebench -- CUDA implementation (benchmark class G).
#
#   make                 -> build/default/slimebench-cuda
#   make PROFILE=fastmath -> the tier-C comparison
#
# ARCH note: the CUDA 12.0 toolkit in this environment predates Blackwell and
# cannot emit sm_120 SASS. Compiling to PTX for compute_90 and letting the
# driver JIT it forward works and is the supported path; override ARCH if your
# toolkit knows your card natively, which avoids the one-off JIT at startup.

NVCC    ?= nvcc
PROFILE ?= default
ARCH    ?= compute_90

# SPEC-1 section 1.2: no FMA contraction, and a real division rather than a
# reciprocal approximation. -fmad=false is the one that matters -- without it
# nvcc fuses `4.0f*c + acc` and the diffusion pass stops being bit-exact.
FPFLAGS := -fmad=false --prec-div=true --prec-sqrt=true --ftz=false

ifeq ($(PROFILE),default)
  OPT := -O3
else ifeq ($(PROFILE),fastmath)          # (C) deliberately breaks tier A
  OPT := -O3 --use_fast_math
  FPFLAGS :=
else
  $(error unknown PROFILE '$(PROFILE)')
endif

BUILDDIR := build/$(PROFILE)
BIN      := $(BUILDDIR)/slimebench-cuda

NVCCFLAGS := -std=c++17 $(OPT) $(FPFLAGS) \
             -gencode arch=$(ARCH),code=$(ARCH) \
             -Xcompiler -Wall

.PHONY: all clean distclean print-config

all: $(BIN)

$(BUILDDIR):
	@mkdir -p $(BUILDDIR)

$(BIN): slimebench.cu ../c/dirtable.h | $(BUILDDIR)
	$(NVCC) $(NVCCFLAGS) $< -o $@

print-config:
	@echo "NVCC=$(NVCC)  PROFILE=$(PROFILE)  ARCH=$(ARCH)"
	@echo "NVCCFLAGS=$(NVCCFLAGS)"

clean:
	rm -rf $(BUILDDIR)

distclean:
	rm -rf build
