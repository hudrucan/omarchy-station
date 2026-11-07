CACHE_HOME := $(or $(XDG_CACHE_HOME),$(HOME)/.cache)
DATA_HOME := $(or $(XDG_DATA_HOME),$(HOME)/.local/share)
BUILD_DIR ?= $(CACHE_HOME)/omastation/build
BUILDDIR ?= $(CACHE_HOME)/omastation/makepkg
SRCDEST ?= $(CACHE_HOME)/omastation/sources
PKGDEST ?= $(DATA_HOME)/omastation/packages
LOGDEST ?= $(CACHE_HOME)/omastation/logs
ZIG_GLOBAL_CACHE_DIR ?= $(CACHE_HOME)/zig
ZIG_LOCAL_CACHE_DIR = $(BUILD_DIR)/zig-cache

ZIG ?= mise exec -- zig
OPTIMIZE ?= ReleaseSafe
JOBS ?= $(shell nproc)
MAKEPKG_FLAGS ?=
BENCH_ARGS ?= --size 640x360 --reps 1 --only kernels,lossless

export ZIG_GLOBAL_CACHE_DIR ZIG_LOCAL_CACHE_DIR

ZIG_BUILD_FLAGS = --cache-dir "$(ZIG_LOCAL_CACHE_DIR)" \
	--prefix "$(BUILD_DIR)/out" -Doptimize=$(OPTIMIZE) -j$(JOBS)
PACKAGE_ENV = BUILDDIR="$(BUILDDIR)" SRCDEST="$(SRCDEST)" \
	PKGDEST="$(PKGDEST)" LOGDEST="$(LOGDEST)"

.PHONY: all build plugin check bench test-capture test-window-fit test-cursor package install clean

all: build

build:
	$(ZIG) build $(ZIG_BUILD_FLAGS)

plugin:
	$(ZIG) build plugin $(ZIG_BUILD_FLAGS)

check:
	$(ZIG) build check $(ZIG_BUILD_FLAGS) --summary all

bench:
	$(ZIG) build bench $(ZIG_BUILD_FLAGS) -- $(BENCH_ARGS)

test-capture:
	$(ZIG) build capbench $(ZIG_BUILD_FLAGS) -- --output BASE --mode dmabuf --diff verify --frames 60 --warmup 3 --check-every 1

test-window-fit:
	ZIG="$(ZIG)" OPTIMIZE="$(OPTIMIZE)" JOBS="$(JOBS)" python3 tests/window_fit.py

test-cursor: plugin
	OMASTATION_PLUGIN="$(BUILD_DIR)/out/lib/omastation-plugin.so" python3 tests/cursor_snapshot.py

# Snapshot the working tree, including uncommitted source, without build artifacts.
package:
	mkdir -p "$(BUILDDIR)" "$(SRCDEST)" "$(PKGDEST)" "$(LOGDEST)"
	tar --exclude-vcs --exclude-vcs-ignores --transform='s,^\.,omastation,' \
		-cf "$(SRCDEST)/omastation.tar" .
	mise exec -- env $(PACKAGE_ENV) JOBS="$(JOBS)" \
		makepkg --dir packaging/omastation --force $(MAKEPKG_FLAGS)

install:
	$(MAKE) package MAKEPKG_FLAGS="$(MAKEPKG_FLAGS) --install"

# Keep the shared toolchain, global Zig cache, makepkg work trees and packages.
clean:
	rm -rf -- "$(BUILD_DIR)/zig-cache" "$(BUILD_DIR)/out"
