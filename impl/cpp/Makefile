# slimebench -- C++ implementation.
#
#   make CXX=g++     PROFILE=o3
#   make CXX=clang++ PROFILE=ofast-native
#   make all-profiles CXX=g++
#
# Binaries: build/<cxx>-<profile>/slimebench-{headless,sdl2,raylib}

CXX     ?= g++
PROFILE ?= o2

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
else ifeq ($(PROFILE),o3-v3)
  # x86-64-v3 == AVX2, no AVX-512. Lets the SIMD kernel be measured at 8 lanes
  # against the 16 lanes -march=native gives on this Zen 5 part.
  OPTFLAGS := -O3 -march=x86-64-v3 -mtune=native
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

# SPEC-1 section 1.2: no FMA contraction, no reassociation.
FPFLAGS ?= -ffp-contract=off -fno-fast-math

WARN     := -Wall -Wextra -Wno-unused-parameter
STD      := -std=c++20
CXXFLAGS := $(STD) $(WARN) $(OPTFLAGS) $(FPFLAGS) $(EXTRA_CXXFLAGS)
LDFLAGS  := $(OPTFLAGS) $(EXTRA_LDFLAGS)
# std::jthread/std::barrier need the pthread runtime on libstdc++.
LDLIBS   := -lpthread

CXXNAME  := $(notdir $(CXX))
BUILDDIR := build/$(CXXNAME)-$(PROFILE)

CORE_SRC := sim.cpp cli.cpp parallel.cpp simd.cpp
CORE_OBJ := $(addprefix $(BUILDDIR)/,$(CORE_SRC:.cpp=.o))
HEADERS  := dirtable.hpp sim.hpp cli.hpp agent.hpp parallel.hpp simd.hpp

HEADLESS := $(BUILDDIR)/slimebench-headless
SDL2BIN  := $(BUILDDIR)/slimebench-sdl2
RAYBIN   := $(BUILDDIR)/slimebench-raylib

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

$(BUILDDIR)/%.o: %.cpp $(HEADERS) | $(BUILDDIR)
	$(CXX) $(CXXFLAGS) -c $< -o $@

$(HEADLESS): $(CORE_OBJ) $(BUILDDIR)/main_headless.o
	$(CXX) $(LDFLAGS) $^ -o $@ $(LDLIBS)

$(BUILDDIR)/main_sdl2.o: main_sdl2.cpp $(HEADERS) | $(BUILDDIR)
	@test -n "$(SDL2_LIBS)" || { echo "error: SDL2 not found (apt install libsdl2-dev)"; exit 1; }
	$(CXX) $(CXXFLAGS) $(SDL2_CFLAGS) -c $< -o $@

$(SDL2BIN): $(CORE_OBJ) $(BUILDDIR)/main_sdl2.o
	$(CXX) $(LDFLAGS) $^ -o $@ $(SDL2_LIBS) $(LDLIBS)

$(BUILDDIR)/main_raylib.o: main_raylib.cpp $(HEADERS) | $(BUILDDIR)
	@test -n "$(RAY_LIBS)" || { echo "error: raylib not found (scripts/setup-wsl.sh render)"; exit 1; }
	$(CXX) $(CXXFLAGS) $(RAY_CFLAGS) -c $< -o $@

$(RAYBIN): $(CORE_OBJ) $(BUILDDIR)/main_raylib.o
	$(CXX) $(LDFLAGS) $^ -o $@ $(RAY_LIBS) $(LDLIBS)

PROFILES := o0 o1 o2 o3 os o3-native o3-lto o3-native-lto ofast ofast-native

all-profiles:
	@for p in $(PROFILES); do \
	  echo "==> $(CXXNAME) $$p"; \
	  $(MAKE) --no-print-directory CXX=$(CXX) PROFILE=$$p headless || exit 1; \
	done

print-config:
	@echo "CXX=$(CXX)  PROFILE=$(PROFILE)"
	@echo "CXXFLAGS=$(CXXFLAGS)"
	@echo "OUT=$(BUILDDIR)"

clean:
	rm -rf $(BUILDDIR)

distclean:
	rm -rf build
