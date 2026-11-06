# Building and packaging

The Makefile is the common entry point for local development, the installer and
CI. `build.zig` defines server compilation, Wayland protocol generation and Zig
tests. `plugin/build.sh` defines native plugin compilation and is also installed
for the Hyprland package hook. `PKGBUILD` calls these build steps and stages the
system files; it never downloads or installs a compiler.

## Dependencies

On Omarchy, `./install-omarchy` installs dependencies and the built package. To
prepare a development machine without installing Omastation:

```sh
omarchy pkg add \
  base-devel mise python hyprland uwsm jq openssl pam libva \
  mesa vulkan-headers vulkan-icd-loader openh264 \
  libxkbcommon opus libfdk-aac gsm fuse3 libpipewire
mise trust
mise install
```

On Arch without Omarchy, install the same dependency list through pacman.
`mise.toml` pins Zig; `build.zig.zon` declares the minimum supported version and
the server version. The compiler lives in mise's shared installation directory,
not in a package build tree. There is no compiler download during `make build`.

Vulkan and OpenH264 headers are needed to build even when a particular machine
uses shared-memory capture or VA-API encoding. OpenH264's library is loaded at
runtime when software H.264 is selected. Install the appropriate Vulkan and
VA-API drivers for your GPU to use hardware acceleration.

## Commands

| Command | Work performed |
| --- | --- |
| `make build` | Build the server in ReleaseSafe mode |
| `make plugin` | Build the native plugin against installed Hyprland |
| `make check` | Build server/plugin, check formatting and shell syntax, run Zig and Python tests |
| `make bench` | Run the short CPU benchmark; set `BENCH_ARGS` for a longer run |
| `make test-capture` | Run the upstream DMA-BUF capture benchmark on an isolated `BASE` output |
| `make test-window-fit` | Exercise floating-window recovery in a temporary nested compositor |
| `make package` | Snapshot the working tree and build an Arch package |
| `make install` | Build the package and install it through makepkg/pacman |
| `make hyprland-package` | Build the separate patched compositor package |
| `make clean` | Remove development build outputs and the local Zig cache |

The native plugin is rebuilt when its target is requested so changes to installed
Hyprland headers and its build ID cannot leave a stale plugin. Normal server
builds do not compile the plugin or Hyprland itself.

The checks use fake desktop-start commands and a fake compositor where applicable.
They do not enable units, change login settings or establish a real remote desktop
session. A successful check is not a live client compatibility or display-isolation
test.

The graphics log counts input events serviced during bounded VA-API waits.
Graphics/control PDUs remain ordered with input. GPU capture and masked NV12
conversion use the upstream Vulkan pipeline; `--no-gpu-capture` selects SHM.
`present->flush` p50/p95 retains the latest 512 valid samples per log interval,
measuring presentation to local socket flush, excluding network/client decoding.

`make test-capture` runs the upstream `capbench` with GPU/CPU diff verification
against a separate compositor's moving output named `BASE`.
Set its `WAYLAND_DISPLAY` and `XDG_RUNTIME_DIR`; the command
uses the same external build directory as `make build`. It is separate from
`make check` and must not be pointed at a personal desktop.

`make test-window-fit` starts a separate Hyprland compositor with synthetic
Quickshell windows and cleans it up afterwards. It checks a 2K-to-portrait resize,
an inactive workspace, application minimum sizes, and preservation of windows
that already fit or belong to another monitor. It also checks that growing the
display does not enlarge windows. It needs Hyprland, Quickshell and one running
Hyprland instance for the nested renderer; it does not resize the live desktop.


For fewer parallel jobs or another build location:

```sh
make check JOBS=2
make build BUILD_DIR=/path/to/build
make build ZIG=/path/to/zig OPTIMIZE=Debug
```

## Files outside the checkout

| Data | Default location |
| --- | --- |
| Development build cache | `~/.cache/omastation/build/zig-cache` |
| Development executable | `~/.cache/omastation/build/out/bin/omastation` |
| Development plugin | `~/.cache/omastation/build/out/lib/omastation-plugin.so` |
| Shared Zig cache | `~/.cache/zig` |
| Package source snapshots/downloads | `~/.cache/omastation/sources` |
| makepkg source, build and staging directories | `~/.cache/omastation/makepkg` |
| Package log destination (with makepkg `--log`) | `~/.cache/omastation/logs` |
| Built packages | `~/.local/share/omastation/packages` |

`XDG_CACHE_HOME` and `XDG_DATA_HOME` replace the corresponding default roots.
`BUILD_DIR`, `ZIG_GLOBAL_CACHE_DIR`, `BUILDDIR`, `SRCDEST`, `PKGDEST` and `LOGDEST`
can be overridden. Keep build directories in a stable location to retain
incremental build state. `make clean` leaves the shared toolchain/global cache,
makepkg work trees, source archives and finished packages intact.

## Packaging the working tree

`make package` creates `omastation.tar` from the current checkout, excluding Git
metadata and ignored files, then gives the snapshot to makepkg. This includes
uncommitted and new source files.

The archive is extracted in the external makepkg directory. Its server and plugin
are built through the same Makefile, using the pinned compiler supplied on PATH.
The output keeps DWARF information for crash backtraces. Package metadata and
system integration live under `packaging/omastation/`.

Package names use the version from `build.zig.zon` and `pkgrel` from `PKGBUILD`.
Repeated development builds replace the same package filename; retain a copy
elsewhere if you need that exact build for rollback. Do not run two package builds
against the same source/build directories concurrently.

The optional patched Hyprland build has its own makepkg tree. It honours `JOBS`
through `CMAKE_BUILD_PARALLEL_LEVEL` and is requested explicitly:

```sh
make hyprland-package JOBS=2
```

Add `MAKEPKG_FLAGS=--install` to install it, or `MAKEPKG_FLAGS=--log` to retain
build logs. Neither normal server builds nor package updates rebuild Hyprland.
