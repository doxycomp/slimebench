# slimebench -- OpenGL 4.3 compute implementation (benchmark class G).
#
#   make                 -> build/default/slimebench-gl
#
# Run against the discrete GPU under WSL2 with:
#   GALLIUM_DRIVER=d3d12 MESA_D3D12_DEFAULT_ADAPTER_NAME=NVIDIA ./slimebench-gl ...
# Without those it runs on llvmpipe. The binary prints the renderer string, so
# a software run is always visible in the output rather than silently assumed
# to be the GPU.

CC      ?= gcc
PROFILE ?= default

ifeq ($(PROFILE),default)
  OPT := -O2
else
  $(error unknown PROFILE '$(PROFILE)')
endif

# The host side does no float work that matters, but keep the same flags as
# the other C targets so nothing drifts.
FPFLAGS := -ffp-contract=off -fno-fast-math
CFLAGS  := -std=c11 -D_POSIX_C_SOURCE=200809L -Wall -Wextra -Wno-unused-parameter \
           $(OPT) $(FPFLAGS)

BUILDDIR := build/$(PROFILE)
BIN      := $(BUILDDIR)/slimebench-gl

SDL2_CFLAGS := $(shell pkg-config --cflags sdl2 2>/dev/null)
SDL2_LIBS   := $(shell pkg-config --libs   sdl2 2>/dev/null)

.PHONY: all clean distclean print-config

all: $(BIN)

$(BUILDDIR):
	@mkdir -p $(BUILDDIR)

$(BIN): slimebench_gl.c gl_shaders.h ../c/dirtable.h | $(BUILDDIR)
	@test -n "$(SDL2_LIBS)" || { echo "error: SDL2 not found (apt install libsdl2-dev)"; exit 1; }
	$(CC) $(CFLAGS) $(SDL2_CFLAGS) $< -o $@ $(SDL2_LIBS) -lm

print-config:
	@echo "CC=$(CC)  PROFILE=$(PROFILE)"
	@echo "CFLAGS=$(CFLAGS)"

clean:
	rm -rf $(BUILDDIR)

distclean:
	rm -rf build
