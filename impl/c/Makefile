# slimebench -- C implementation.
#
# The compiler and the optimisation profile are the two axes we benchmark, so
# both are variables and every combination lands in its own build directory:
#
#   make CC=gcc   PROFILE=o3
#   make CC=clang PROFILE=ofast-native
#   make all-profiles CC=gcc
#
# Binaries: build/<cc>-<profile>/slimebench-{headless,sdl2}

CC      ?= gcc
PROFILE ?= o2

# --- optimisation profiles ---------------------------------------------------
# Profiles marked (C) violate SPEC-1 section 1.2 on purpose: they are the
# fast-math conformance class, and measuring what they buy is the point.

ifeq ($(PROFILE),o0)
  OPTFLAGS := -O0
else ifeq ($(PROFILE),o1)
  OPTFLAGS := -O1
else ifeq ($(PROFILE),o2)
  OPTFLAGS := -O2
else ifeq ($(PROFILE),o3)
  OPTFLAGS := -O3
else ifeq ($(PROFILE),os)
  OPTFLAGS := -Os
else ifeq ($(PROFILE),o3-native)
  OPTFLAGS := -O3 -march=native -mtune=native
else ifeq ($(PROFILE),o3-lto)
  OPTFLAGS := -O3 -flto
else ifeq ($(PROFILE),o3-native-lto)
  OPTFLAGS := -O3 -march=native -mtune=native -flto
else ifeq ($(PROFILE),ofast)                       # (C) fast-math
  OPTFLAGS := -Ofast
  FPFLAGS  :=
else ifeq ($(PROFILE),ofast-native)                # (C) fast-math
  OPTFLAGS := -Ofast -march=native -mtune=native
  FPFLAGS  :=
else
  $(error unknown PROFILE '$(PROFILE)')
endif

# SPEC-1 section 1.2: no FMA contraction, no reassociation. Overridden to empty
# by the ofast profiles above.
FPFLAGS ?= -ffp-contract=off -fno-fast-math

WARN     := -Wall -Wextra -Wno-unused-parameter
STD      := -std=c11
# strict C11 hides clock_gettime; ask for POSIX 2008 explicitly rather than
# falling back to -std=gnu11 (we want the same language across compilers).
DEFS     := -D_POSIX_C_SOURCE=200809L
CFLAGS   := $(STD) $(DEFS) $(WARN) $(OPTFLAGS) $(FPFLAGS) $(EXTRA_CFLAGS)
LDFLAGS  := $(OPTFLAGS) $(EXTRA_LDFLAGS)
# pthreads rather than OpenMP: builds with gcc and clang alike, no libomp-dev.
LDLIBS   := -lm -lpthread

CCNAME   := $(notdir $(CC))
BUILDDIR := build/$(CCNAME)-$(PROFILE)

CORE_SRC := sb_core.c sb_cli.c sb_parallel.c
CORE_OBJ := $(addprefix $(BUILDDIR)/,$(CORE_SRC:.c=.o))

HEADLESS := $(BUILDDIR)/slimebench-headless
SDL2BIN  := $(BUILDDIR)/slimebench-sdl2
RAYBIN   := $(BUILDDIR)/slimebench-raylib
HEADERS  := dirtable.h sb_core.h sb_cli.h sb_render.h sb_agent.h sb_parallel.h

SDL2_CFLAGS := $(shell pkg-config --cflags sdl2 2>/dev/null)
SDL2_LIBS   := $(shell pkg-config --libs   sdl2 2>/dev/null)
RAY_CFLAGS  := $(shell pkg-config --cflags raylib 2>/dev/null)
RAY_LIBS    := $(shell pkg-config --libs   raylib 2>/dev/null)

.PHONY: all headless sdl2 raylib clean distclean all-profiles print-config

all: headless

headless: $(HEADLESS)

sdl2: $(SDL2BIN)

raylib: $(RAYBIN)

$(BUILDDIR):
	@mkdir -p $(BUILDDIR)

$(BUILDDIR)/%.o: %.c $(HEADERS) | $(BUILDDIR)
	$(CC) $(CFLAGS) -c $< -o $@

$(HEADLESS): $(CORE_OBJ) $(BUILDDIR)/main_headless.o
	$(CC) $(LDFLAGS) $^ -o $@ $(LDLIBS)

$(BUILDDIR)/main_sdl2.o: main_sdl2.c $(HEADERS) | $(BUILDDIR)
	@test -n "$(SDL2_LIBS)" || { echo "error: SDL2 not found (apt install libsdl2-dev)"; exit 1; }
	$(CC) $(CFLAGS) $(SDL2_CFLAGS) -c $< -o $@

$(SDL2BIN): $(CORE_OBJ) $(BUILDDIR)/main_sdl2.o
	$(CC) $(LDFLAGS) $^ -o $@ $(SDL2_LIBS) $(LDLIBS)

$(BUILDDIR)/main_raylib.o: main_raylib.c $(HEADERS) | $(BUILDDIR)
	@test -n "$(RAY_LIBS)" || { echo "error: raylib not found (scripts/setup-wsl.sh render)"; exit 1; }
	$(CC) $(CFLAGS) $(RAY_CFLAGS) -c $< -o $@

$(RAYBIN): $(CORE_OBJ) $(BUILDDIR)/main_raylib.o
	$(CC) $(LDFLAGS) $^ -o $@ $(RAY_LIBS) $(LDLIBS)

PROFILES := o0 o1 o2 o3 os o3-native o3-lto o3-native-lto ofast ofast-native

all-profiles:
	@for p in $(PROFILES); do \
	  echo "==> $(CCNAME) $$p"; \
	  $(MAKE) --no-print-directory CC=$(CC) PROFILE=$$p headless || exit 1; \
	done

print-config:
	@echo "CC=$(CC)  PROFILE=$(PROFILE)"
	@echo "CFLAGS=$(CFLAGS)"
	@echo "OUT=$(BUILDDIR)"

clean:
	rm -rf $(BUILDDIR)

distclean:
	rm -rf build
