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
omarchy pkg add base-devel mise python hyprland uwsm jq openssl pam libva libdrm mesa libxkbcommon opus libfdk-aac gsm fuse3 libpipewire
mise trust
mise install
```

On Arch without Omarchy, install the same dependency list through pacman.
`mise.toml` pins Zig; `build.zig.zon` declares the minimum supported version and
the server version. The compiler lives in mise's shared installation directory,
not in a package build tree. There is no compiler download during `make build`.

## Commands

| Command | Work performed |
| --- | --- |
| `make build` | Build the server in ReleaseSafe mode |
| `make plugin` | Build the native plugin against installed Hyprland |
| `make check` | Build server/plugin, check formatting and shell syntax, run Zig and Python tests |
| `make bench` | Run the short CPU benchmark; set `BENCH_ARGS` for a longer run |
| `make test-capture` | Compare DMA-BUF and SHM on a static `BASE` output in a test compositor |
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

`make test-capture` is an optional GPU integration test for a static output
named `BASE` in a separate test compositor. It compares DMA-BUF pixels against
shared-memory capture, exercises VA-API import, and reports static-frame timings.
It also checks import-cache reuse and invalidation, deferred CPU reference images,
and retained-buffer lifetime after capture and Wayland-client teardown.
It requires working DMA-BUF capture and a VA-API H.264 driver; it is separate from
`make check`. Run it with the test compositor's `WAYLAND_DISPLAY` and
`XDG_RUNTIME_DIR`; it uses the same external build directory as `make build`.
For resize lifetime checks, set `OMASTATION_CAPTURE_TEST_ALLOW_RESIZE=1` with a
private runtime directory under `/tmp`. This also changes the test output `BASE`
to 960x641; it is not intended for a live desktop.

`make test-window-fit` starts a separate Hyprland compositor with synthetic
Quickshell windows and cleans it up afterwards. It checks a 2K-to-portrait resize,
an inactive workspace, application minimum sizes, and preservation of windows
that already fit or belong to another monitor. It also checks that growing the
display does not enlarge windows. It needs Hyprland, Quickshell and one running
Hyprland instance for the nested renderer; it does not resize the live desktop.

The graphics log reports DMA-BUF frame counts, including partial updates, and
`present->flush` p50/p95 latency. These measure compositor presentation to the
server's local socket flush, excluding network transit and client decoding.
Each five-second interval retains at most its latest 512 latency samples; frames
without a valid presentation timestamp are omitted. This helps compare latency
when both builds already reach the display's frame rate.

The same log counts input events serviced during bounded VA-API waits and stale
captures replaced before encoding. Capture can run one frame ahead once the
previous RGB reference is safe to reuse. The latest unencoded picture is retained
under backpressure, including the final picture when the screen stops changing;
encoded H.264 pictures are never dropped. Control PDUs remain ordered with input.

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
